"""
ASG Lifecycle Hook Handler
--------------------------
Triggered by EventBridge when an EC2 instance enters the
autoscaling:EC2_INSTANCE_TERMINATING lifecycle hook wait state.

Flow:
  1. Parse instance ID and lifecycle token from the event
  2. Send SSM Run Command to execute the license-drop script on the instance
  3. Poll for SSM command completion (with heartbeat renewal to avoid timeout)
  4. Complete lifecycle action: CONTINUE (success) or ABANDON (failure)
  5. Publish SNS notification with outcome

Silent failure prevention:
  - All exceptions caught and lifecycle action completed with ABANDON
  - DLQ captures any Lambda invocation failures (configured in Terraform)
  - CloudWatch alarm fires on Lambda errors and DLQ depth > 0
"""

import boto3
import json
import logging
import os
import time

logger = logging.getLogger()
logger.setLevel(logging.INFO)

autoscaling = boto3.client("autoscaling")
ssm = boto3.client("ssm")
sns = boto3.client("sns")

ASG_NAME       = os.environ["ASG_NAME"]
SNS_TOPIC_ARN  = os.environ["SNS_TOPIC_ARN"]
HOOK_NAME      = os.environ["HOOK_NAME"]
DEFAULT_RESULT = os.environ.get("DEFAULT_RESULT", "ABANDON")

# SSM command to run on the terminating instance
# Replace this with your actual vendor license drop command
LICENSE_DROP_COMMAND = """
#!/bin/bash
set -e
echo "Dropping vendor license for instance $(ec2-metadata --instance-id | cut -d' ' -f2)"
# /opt/vendor/bin/drop-license --instance-id $(ec2-metadata --instance-id | cut -d' ' -f2)
echo "License dropped successfully"
"""


def handler(event, context):
    logger.info("Received event: %s", json.dumps(event))

    # EventBridge wraps the ASG event in event["detail"]
    detail       = event.get("detail", {})
    instance_id  = detail.get("EC2InstanceId")
    token        = detail.get("LifecycleActionToken")
    hook_name    = detail.get("LifecycleHookName", HOOK_NAME)
    asg_name     = detail.get("AutoScalingGroupName", ASG_NAME)

    if not instance_id or not token:
        logger.error("Missing instance_id or lifecycle token in event — cannot complete hook")
        _notify(f"ERROR: Lifecycle hook received malformed event. Manual intervention required.\nEvent: {json.dumps(event)}")
        return

    logger.info("Processing termination for instance %s", instance_id)
    result = DEFAULT_RESULT  # safe default — overridden on success

    try:
        # Step 1: Send SSM Run Command to the terminating instance
        command_id = _send_ssm_command(instance_id)
        logger.info("SSM command sent: %s", command_id)

        # Step 2: Poll for completion, renewing heartbeat every 2 minutes
        _wait_for_ssm(command_id, instance_id, asg_name, hook_name, token, context)

        result = "CONTINUE"
        logger.info("License drop successful for %s — completing lifecycle with CONTINUE", instance_id)
        _notify(f"✅ Lifecycle hook SUCCESS\nInstance: {instance_id}\nASG: {asg_name}\nLicense dropped cleanly. Instance will now terminate.")

    except SSMCommandFailed as e:
        # SSM command ran but exited non-zero — license drop script failed
        logger.error("SSM command failed for %s: %s", instance_id, str(e))
        result = DEFAULT_RESULT
        _notify(f"❌ Lifecycle hook FAILURE — SSM command failed\nInstance: {instance_id}\nASG: {asg_name}\nError: {str(e)}\nLifecycle result: {result}\nManual license cleanup may be required.")

    except InstanceUnreachable as e:
        # SSM agent not responding — instance may already be unhealthy
        # Fall back to direct license server API call if available
        logger.error("Instance %s unreachable via SSM: %s", instance_id, str(e))
        result = DEFAULT_RESULT
        _notify(f"⚠️ Lifecycle hook WARNING — Instance unreachable via SSM\nInstance: {instance_id}\nASG: {asg_name}\nAttempt direct license server deregistration manually.\nLifecycle result: {result}")

    except Exception as e:
        logger.exception("Unexpected error processing lifecycle hook for %s", instance_id)
        result = DEFAULT_RESULT
        _notify(f"❌ Lifecycle hook UNEXPECTED ERROR\nInstance: {instance_id}\nASG: {asg_name}\nError: {str(e)}\nLifecycle result: {result}")

    finally:
        # Always complete the lifecycle action — never leave instance in wait state
        # without an explicit decision. This runs even if an exception occurred above.
        try:
            autoscaling.complete_lifecycle_action(
                LifecycleHookName=hook_name,
                AutoScalingGroupName=asg_name,
                LifecycleActionToken=token,
                LifecycleActionResult=result,
                InstanceId=instance_id,
            )
            logger.info("Lifecycle action completed: %s for instance %s", result, instance_id)
        except Exception as complete_err:
            # This is the worst case — lifecycle token may have expired.
            # The heartbeat renewal in _wait_for_ssm should prevent this.
            logger.error("CRITICAL: Failed to complete lifecycle action for %s: %s", instance_id, str(complete_err))
            _notify(f"🚨 CRITICAL: Could not complete lifecycle action for {instance_id}. Instance may be stuck in Terminating:Wait. Manual intervention required.")


def _send_ssm_command(instance_id: str) -> str:
    """Send SSM Run Command to the instance. Returns command ID."""
    response = ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": [LICENSE_DROP_COMMAND]},
        TimeoutSeconds=280,  # slightly less than Lambda timeout
        Comment=f"ASG lifecycle hook — license drop for {instance_id}",
    )
    return response["Command"]["CommandId"]


def _wait_for_ssm(command_id: str, instance_id: str, asg_name: str,
                  hook_name: str, token: str, context) -> None:
    """
    Poll SSM until the command completes or Lambda is about to time out.
    Renews the lifecycle heartbeat every 2 minutes so the hook doesn't expire.
    """
    poll_interval      = 15   # seconds between SSM status checks
    heartbeat_interval = 120  # seconds between heartbeat renewals

    last_heartbeat = time.time()

    while True:
        # Check remaining Lambda execution time
        remaining_ms = context.get_remaining_time_in_millis()
        if remaining_ms < 30_000:  # < 30 seconds left — bail out safely
            raise Exception(f"Lambda running out of time ({remaining_ms}ms remaining) before SSM completed")

        # Renew heartbeat before it expires
        if time.time() - last_heartbeat >= heartbeat_interval:
            try:
                autoscaling.record_lifecycle_action_heartbeat(
                    LifecycleHookName=hook_name,
                    AutoScalingGroupName=asg_name,
                    LifecycleActionToken=token,
                    InstanceId=instance_id,
                )
                logger.info("Lifecycle heartbeat renewed for %s", instance_id)
                last_heartbeat = time.time()
            except Exception as hb_err:
                logger.warning("Heartbeat renewal failed (may have already completed): %s", str(hb_err))

        # Poll SSM command status
        response = ssm.get_command_invocation(
            CommandId=command_id,
            InstanceId=instance_id,
        )
        status = response["Status"]
        logger.info("SSM command %s status: %s", command_id, status)

        if status == "Success":
            return  # license dropped successfully

        elif status in ("Failed", "Cancelled", "TimedOut", "Cancelling"):
            raise SSMCommandFailed(
                f"SSM command {command_id} ended with status {status}. "
                f"Output: {response.get('StandardErrorContent', 'no output')}"
            )

        elif status == "InvalidInstanceId":
            raise InstanceUnreachable(
                f"Instance {instance_id} not registered with SSM or agent not running"
            )

        # Still in progress (InProgress, Pending, Delayed) — keep polling
        time.sleep(poll_interval)


def _notify(message: str) -> None:
    """Publish an SNS notification. Never raises — notification failure is non-fatal."""
    try:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="ASG Lifecycle Hook Event",
            Message=message,
        )
    except Exception as e:
        logger.warning("SNS notification failed (non-fatal): %s", str(e))


class SSMCommandFailed(Exception):
    pass


class InstanceUnreachable(Exception):
    pass
