import json
import sys
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from cost_hygiene.handler import DEFAULT_PRICES, Scanner, Settings, format_message, summarize, to_csv

REGION = "sa-east-1"


@pytest.fixture(autouse=True)
def aws_env(monkeypatch):
    for var, value in {
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "AWS_SESSION_TOKEN": "testing",
        "AWS_DEFAULT_REGION": REGION,
        "AWS_REGION": REGION,
    }.items():
        monkeypatch.setenv(var, value)


def settings(**overrides):
    base = {
        "required_tags": ("CostCenter", "Owner"),
        "snapshot_max_age_days": 90,
        "stopped_max_days": 14,
        "tag_candidates": False,
        "prices": DEFAULT_PRICES,
    }
    base.update(overrides)
    return Settings(**base)


def tags(**kv):
    return [{"Key": k, "Value": v} for k, v in kv.items()]


@pytest.fixture
def ec2():
    with mock_aws():
        yield boto3.client("ec2", region_name=REGION)


def launch_instance(ec2, **tag_kv):
    image_id = ec2.describe_images(Owners=["amazon"])["Images"][0]["ImageId"]
    spec = {"ResourceType": "instance", "Tags": tags(**tag_kv)} if tag_kv else None
    kwargs = {"ImageId": image_id, "MinCount": 1, "MaxCount": 1, "InstanceType": "t3.micro"}
    if spec:
        kwargs["TagSpecifications"] = [spec]
    return ec2.run_instances(**kwargs)["Instances"][0]["InstanceId"]


class TestFindings:
    def test_volumen_sin_adjuntar_con_coste(self, ec2):
        vol = ec2.create_volume(AvailabilityZone=f"{REGION}a", Size=100, VolumeType="gp3")["VolumeId"]

        findings = Scanner(ec2, REGION, settings()).unattached_volumes()

        assert [f.resource_id for f in findings] == [vol]
        assert findings[0].monthly_cost_usd == Decimal("8.00")

    def test_eip_sin_asociar(self, ec2):
        ec2.allocate_address(Domain="vpc")
        findings = Scanner(ec2, REGION, settings()).unassociated_eips()
        assert len(findings) == 1
        assert findings[0].monthly_cost_usd == Decimal("3.65")

    def test_eip_asociada_no_es_hallazgo(self, ec2):
        instance_id = launch_instance(ec2, CostCenter="x", Owner="y")
        alloc = ec2.allocate_address(Domain="vpc")["AllocationId"]
        ec2.associate_address(AllocationId=alloc, InstanceId=instance_id)
        assert Scanner(ec2, REGION, settings()).unassociated_eips() == []

    def test_snapshot_antiguo_que_no_respalda_ami(self, ec2):
        vol = ec2.create_volume(AvailabilityZone=f"{REGION}a", Size=50)["VolumeId"]
        snap = ec2.create_snapshot(VolumeId=vol)["SnapshotId"]
        future = datetime.now(UTC) + timedelta(days=120)

        findings = Scanner(ec2, REGION, settings(), now=future).old_snapshots()

        assert snap in [f.resource_id for f in findings]
        assert "120 días" in next(f for f in findings if f.resource_id == snap).detail

    def test_snapshot_reciente_no_es_hallazgo(self, ec2):
        vol = ec2.create_volume(AvailabilityZone=f"{REGION}a", Size=50)["VolumeId"]
        snap = ec2.create_snapshot(VolumeId=vol)["SnapshotId"]
        findings = Scanner(ec2, REGION, settings()).old_snapshots()
        assert snap not in [f.resource_id for f in findings]

    def test_snapshot_de_una_ami_propia_se_respeta(self, ec2):
        instance_id = launch_instance(ec2, CostCenter="x", Owner="y")
        image_id = ec2.create_image(InstanceId=instance_id, Name="golden")["ImageId"]
        ami_snapshots = {
            m["Ebs"]["SnapshotId"]
            for m in ec2.describe_images(ImageIds=[image_id])["Images"][0]["BlockDeviceMappings"]
            if "Ebs" in m
        }
        future = datetime.now(UTC) + timedelta(days=365)

        flagged = {f.resource_id for f in Scanner(ec2, REGION, settings(), now=future).old_snapshots()}

        assert ami_snapshots and not (ami_snapshots & flagged)

    def test_instancia_detenida_hace_mucho(self, ec2):
        instance_id = launch_instance(ec2, CostCenter="x", Owner="y")
        ec2.stop_instances(InstanceIds=[instance_id])
        future = datetime.now(UTC) + timedelta(days=30)

        findings = Scanner(ec2, REGION, settings(), now=future).long_stopped_instances()

        assert [f.resource_id for f in findings] == [instance_id]
        assert findings[0].monthly_cost_usd > 0

    def test_instancia_detenida_recientemente_no_es_hallazgo(self, ec2):
        instance_id = launch_instance(ec2, CostCenter="x", Owner="y")
        ec2.stop_instances(InstanceIds=[instance_id])
        assert Scanner(ec2, REGION, settings()).long_stopped_instances() == []

    def test_etiquetas_faltantes(self, ec2):
        ok = launch_instance(ec2, CostCenter="platform", Owner="johan")
        bad = launch_instance(ec2, CostCenter="platform")

        findings = Scanner(ec2, REGION, settings()).missing_tags()
        by_id = {f.resource_id: f for f in findings if f.resource_type == "ec2:instance"}

        assert ok not in by_id
        assert by_id[bad].detail == "faltan: Owner"

    def test_sin_etiquetas_obligatorias_no_se_valida(self, ec2):
        launch_instance(ec2)
        assert Scanner(ec2, REGION, settings(required_tags=())).missing_tags() == []

    def test_etiqueta_candidatos_sin_borrar(self, ec2):
        vol = ec2.create_volume(AvailabilityZone=f"{REGION}a", Size=10)["VolumeId"]
        scanner = Scanner(ec2, REGION, settings(tag_candidates=True))

        tagged = scanner.tag_candidates(scanner.scan())

        assert tagged >= 1
        volume = ec2.describe_volumes(VolumeIds=[vol])["Volumes"][0]
        assert {"Key": "finops:review-requested", "Value": scanner.now.date().isoformat()} in volume["Tags"]


class TestReport:
    def test_resumen_y_csv(self, ec2):
        ec2.create_volume(AvailabilityZone=f"{REGION}a", Size=100, VolumeType="gp3")
        ec2.allocate_address(Domain="vpc")
        findings = Scanner(ec2, REGION, settings(required_tags=())).scan()

        summary = summarize(findings)

        assert summary["by_category"] == {"unassociated-eip": 1, "unattached-volume": 1}
        assert summary["estimated_monthly_savings_usd"] == "11.65"
        csv_text = to_csv(findings)
        assert csv_text.splitlines()[0].startswith("category,resource_type,resource_id")
        assert len(csv_text.splitlines()) == 3
        assert "US$ 11.65" in format_message(summary, "s3://b/k.csv")


def test_handler_extremo_a_extremo(monkeypatch):
    with mock_aws():
        s3 = boto3.client("s3", region_name=REGION)
        s3.create_bucket(Bucket="finops-reports", CreateBucketConfiguration={"LocationConstraint": REGION})
        sns = boto3.client("sns", region_name=REGION)
        topic = sns.create_topic(Name="finops")["TopicArn"]
        boto3.client("ec2", region_name=REGION).create_volume(AvailabilityZone=f"{REGION}a", Size=20)

        monkeypatch.setenv("REPORT_BUCKET", "finops-reports")
        monkeypatch.setenv("TOPIC_ARN", topic)
        monkeypatch.setenv("REQUIRED_TAGS", "CostCenter")
        monkeypatch.setenv("SCAN_REGIONS", REGION)

        from cost_hygiene.handler import handler

        result = handler({})

        assert result["total_findings"] >= 1
        keys = [o["Key"] for o in s3.list_objects_v2(Bucket="finops-reports")["Contents"]]
        assert any(k.endswith("findings.csv") for k in keys)
        summary_key = next(k for k in keys if k.endswith("summary.json"))
        summary = json.loads(s3.get_object(Bucket="finops-reports", Key=summary_key)["Body"].read())
        assert summary["by_category"]["unattached-volume"] == 1
