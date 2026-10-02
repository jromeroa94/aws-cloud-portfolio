import json
import os
import sys
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

REGION = "sa-east-1"
BUCKET = "orders-inbox-test"
TABLE = "orders-test"


@pytest.fixture(autouse=True)
def aws_env(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", REGION)
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
    monkeypatch.setenv("TABLE_NAME", TABLE)


@pytest.fixture
def aws():
    with mock_aws():
        s3 = boto3.client("s3", region_name=REGION)
        s3.create_bucket(Bucket=BUCKET, CreateBucketConfiguration={"LocationConstraint": REGION})

        dynamodb = boto3.resource("dynamodb", region_name=REGION)
        table = dynamodb.create_table(
            TableName=TABLE,
            KeySchema=[{"AttributeName": "order_id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "order_id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )

        sns = boto3.client("sns", region_name=REGION)
        topic_arn = sns.create_topic(Name="orders-test")["TopicArn"]

        # Cola espía suscrita al tema para verificar qué se publica.
        sqs = boto3.client("sqs", region_name=REGION)
        queue_url = sqs.create_queue(QueueName="spy")["QueueUrl"]
        queue_arn = sqs.get_queue_attributes(QueueUrl=queue_url, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
        sns.subscribe(
            TopicArn=topic_arn,
            Protocol="sqs",
            Endpoint=queue_arn,
            Attributes={"RawMessageDelivery": "true"},
        )

        os.environ["TOPIC_ARN"] = topic_arn

        import order_processor.handler as handler_module

        handler_module._processor = None  # fuerza clientes nuevos dentro del mock

        yield {
            "s3": s3,
            "table": table,
            "sns": sns,
            "sqs": sqs,
            "queue_url": queue_url,
            "topic_arn": topic_arn,
            "handler": handler_module,
        }

        handler_module._processor = None


def s3_event_message(key: str, message_id: str = "msg-1", bucket: str = BUCKET) -> dict:
    """Mensaje SQS cuyo cuerpo es un evento 'Object Created' de EventBridge."""
    body = {
        "version": "0",
        "detail-type": "Object Created",
        "source": "aws.s3",
        "detail": {"bucket": {"name": bucket}, "object": {"key": key, "size": 100}},
    }
    return {"messageId": message_id, "body": json.dumps(body)}


def published_events(aws_ctx) -> list[dict]:
    response = aws_ctx["sqs"].receive_message(QueueUrl=aws_ctx["queue_url"], MaxNumberOfMessages=10)
    return [json.loads(m["Body"]) for m in response.get("Messages", [])]
