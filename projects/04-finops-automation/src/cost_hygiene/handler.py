"""Escáner semanal de higiene de costes (FinOps).

Busca recursos que generan coste sin aportar valor y recursos sin las etiquetas de
asignación de costes. Nunca borra nada: genera un informe en S3, envía un resumen a
SNS y, opcionalmente, etiqueta los candidatos para que su dueño decida.

Hallazgos:
  * Volúmenes EBS sin adjuntar.
  * Elastic IPs sin asociar (desde 2024 toda IPv4 pública se cobra por hora).
  * Snapshots antiguos que no respaldan ninguna AMI.
  * Instancias detenidas hace más de N días (siguen pagando EBS).
  * Instancias y volúmenes sin las etiquetas obligatorias.
"""

from __future__ import annotations

import csv
import io
import json
import logging
import os
import re
from collections import Counter
from collections.abc import Iterable
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime, timedelta
from decimal import ROUND_HALF_UP, Decimal
from typing import Any

import boto3

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

# Precios de lista aproximados (USD) de us-east-1. Son configurables por variable de
# entorno porque varían por región; el informe es una estimación, no una factura.
DEFAULT_PRICES = {
    "ebs_gb_month": {
        "gp2": 0.10,
        "gp3": 0.08,
        "io1": 0.125,
        "io2": 0.125,
        "st1": 0.045,
        "sc1": 0.015,
        "standard": 0.05,
    },
    "snapshot_gb_month": 0.05,
    "public_ipv4_month": 3.65,  # 0.005 USD/hora x 730 h
}

# EC2 informa "User initiated (2025-01-31 13:22:41 GMT)"; algunos emuladores usan UTC.
STOPPED_SINCE_RE = re.compile(r"\((\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (?:GMT|UTC)\)")


@dataclass
class Finding:
    category: str
    resource_type: str
    resource_id: str
    region: str
    detail: str
    monthly_cost_usd: Decimal = Decimal("0")
    tags: dict[str, str] = field(default_factory=dict)

    def as_row(self) -> dict[str, Any]:
        row = asdict(self)
        row["monthly_cost_usd"] = str(self.monthly_cost_usd)
        row["tags"] = json.dumps(self.tags, ensure_ascii=False)
        return row


@dataclass(frozen=True)
class Settings:
    required_tags: tuple[str, ...]
    snapshot_max_age_days: int
    stopped_max_days: int
    tag_candidates: bool
    prices: dict[str, Any]

    @classmethod
    def from_env(cls) -> Settings:
        prices = DEFAULT_PRICES
        if os.environ.get("PRICES_JSON"):
            prices = {**DEFAULT_PRICES, **json.loads(os.environ["PRICES_JSON"])}
        return cls(
            required_tags=tuple(t.strip() for t in os.environ.get("REQUIRED_TAGS", "").split(",") if t.strip()),
            snapshot_max_age_days=int(os.environ.get("SNAPSHOT_MAX_AGE_DAYS", "90")),
            stopped_max_days=int(os.environ.get("STOPPED_MAX_DAYS", "14")),
            tag_candidates=os.environ.get("TAG_CANDIDATES", "false").lower() == "true",
            prices=prices,
        )


def _money(value: float | Decimal) -> Decimal:
    return Decimal(str(value)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def _tags(resource: dict[str, Any]) -> dict[str, str]:
    return {t["Key"]: t["Value"] for t in resource.get("Tags", [])}


def _paginate(client: Any, operation: str, key: str, **kwargs: Any) -> Iterable[dict[str, Any]]:
    for page in client.get_paginator(operation).paginate(**kwargs):
        yield from page.get(key, [])


def _volume_cost(volume: dict[str, Any], prices: dict[str, Any]) -> Decimal:
    per_gb = prices["ebs_gb_month"].get(volume.get("VolumeType", "gp2"), prices["ebs_gb_month"]["gp2"])
    return _money(per_gb * volume["Size"])


class Scanner:
    def __init__(self, ec2: Any, region: str, settings: Settings, now: datetime | None = None) -> None:
        self.ec2 = ec2
        self.region = region
        self.settings = settings
        self.now = now or datetime.now(UTC)

    def unattached_volumes(self) -> list[Finding]:
        findings = []
        for vol in _paginate(
            self.ec2, "describe_volumes", "Volumes", Filters=[{"Name": "status", "Values": ["available"]}]
        ):
            findings.append(
                Finding(
                    category="unattached-volume",
                    resource_type="ec2:volume",
                    resource_id=vol["VolumeId"],
                    region=self.region,
                    detail=f"{vol['Size']} GiB {vol.get('VolumeType', '?')} sin adjuntar",
                    monthly_cost_usd=_volume_cost(vol, self.settings.prices),
                    tags=_tags(vol),
                )
            )
        return findings

    def unassociated_eips(self) -> list[Finding]:
        findings = []
        for addr in self.ec2.describe_addresses().get("Addresses", []):
            if addr.get("AssociationId"):
                continue
            findings.append(
                Finding(
                    category="unassociated-eip",
                    resource_type="ec2:elastic-ip",
                    resource_id=addr.get("AllocationId", addr.get("PublicIp", "?")),
                    region=self.region,
                    detail=f"IP {addr.get('PublicIp')} reservada sin uso",
                    monthly_cost_usd=_money(self.settings.prices["public_ipv4_month"]),
                    tags=_tags(addr),
                )
            )
        return findings

    def _snapshots_backing_amis(self) -> set[str]:
        backing = set()
        for image in self.ec2.describe_images(Owners=["self"]).get("Images", []):
            for mapping in image.get("BlockDeviceMappings", []):
                snapshot_id = mapping.get("Ebs", {}).get("SnapshotId")
                if snapshot_id:
                    backing.add(snapshot_id)
        return backing

    def old_snapshots(self) -> list[Finding]:
        cutoff = self.now - timedelta(days=self.settings.snapshot_max_age_days)
        backing = self._snapshots_backing_amis()
        findings = []
        for snap in _paginate(self.ec2, "describe_snapshots", "Snapshots", OwnerIds=["self"]):
            if snap["SnapshotId"] in backing or snap["StartTime"] >= cutoff:
                continue
            age = (self.now - snap["StartTime"]).days
            findings.append(
                Finding(
                    category="old-snapshot",
                    resource_type="ec2:snapshot",
                    resource_id=snap["SnapshotId"],
                    region=self.region,
                    detail=f"{age} días, {snap['VolumeSize']} GiB, no respalda ninguna AMI",
                    # Coste máximo: los snapshots son incrementales, el real puede ser menor.
                    monthly_cost_usd=_money(self.settings.prices["snapshot_gb_month"] * snap["VolumeSize"]),
                    tags=_tags(snap),
                )
            )
        return findings

    def _stopped_since(self, instance: dict[str, Any]) -> datetime | None:
        match = STOPPED_SINCE_RE.search(instance.get("StateTransitionReason", ""))
        if not match:
            return None
        return datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S").replace(tzinfo=UTC)

    def _instances(self) -> Iterable[dict[str, Any]]:
        for reservation in _paginate(self.ec2, "describe_instances", "Reservations"):
            yield from reservation.get("Instances", [])

    def long_stopped_instances(self) -> list[Finding]:
        cutoff = self.now - timedelta(days=self.settings.stopped_max_days)
        volume_ids = []
        candidates = []
        for inst in self._instances():
            if inst["State"]["Name"] != "stopped":
                continue
            since = self._stopped_since(inst)
            if since is None or since > cutoff:
                continue
            ids = [m["Ebs"]["VolumeId"] for m in inst.get("BlockDeviceMappings", []) if "Ebs" in m]
            volume_ids.extend(ids)
            candidates.append((inst, since, ids))

        volumes = {}
        if volume_ids:
            for vol in _paginate(self.ec2, "describe_volumes", "Volumes", VolumeIds=volume_ids):
                volumes[vol["VolumeId"]] = vol

        findings = []
        for inst, since, ids in candidates:
            cost = sum((_volume_cost(volumes[v], self.settings.prices) for v in ids if v in volumes), Decimal("0"))
            findings.append(
                Finding(
                    category="long-stopped-instance",
                    resource_type="ec2:instance",
                    resource_id=inst["InstanceId"],
                    region=self.region,
                    detail=f"detenida hace {(self.now - since).days} días; sigue pagando {len(ids)} volumen(es)",
                    monthly_cost_usd=_money(cost),
                    tags=_tags(inst),
                )
            )
        return findings

    def missing_tags(self) -> list[Finding]:
        if not self.settings.required_tags:
            return []
        findings = []

        def check(resource_type: str, resource_id: str, tags: dict[str, str]) -> None:
            missing = [t for t in self.settings.required_tags if not tags.get(t)]
            if missing:
                findings.append(
                    Finding(
                        category="missing-tags",
                        resource_type=resource_type,
                        resource_id=resource_id,
                        region=self.region,
                        detail="faltan: " + ", ".join(missing),
                        tags=tags,
                    )
                )

        for inst in self._instances():
            if inst["State"]["Name"] != "terminated":
                check("ec2:instance", inst["InstanceId"], _tags(inst))
        for vol in _paginate(self.ec2, "describe_volumes", "Volumes"):
            check("ec2:volume", vol["VolumeId"], _tags(vol))
        return findings

    def scan(self) -> list[Finding]:
        return [
            *self.unattached_volumes(),
            *self.unassociated_eips(),
            *self.old_snapshots(),
            *self.long_stopped_instances(),
            *self.missing_tags(),
        ]

    def tag_candidates(self, findings: list[Finding]) -> int:
        """Marca los candidatos de ahorro para que su dueño los revise (no borra)."""
        ids = [f.resource_id for f in findings if f.category != "missing-tags" and f.resource_type != "ec2:elastic-ip"]
        stamp = self.now.date().isoformat()
        for start in range(0, len(ids), 1000):
            self.ec2.create_tags(
                Resources=ids[start : start + 1000],
                Tags=[{"Key": "finops:review-requested", "Value": stamp}],
            )
        return len(ids)


def summarize(findings: list[Finding]) -> dict[str, Any]:
    by_category = Counter(f.category for f in findings)
    savings = sum((f.monthly_cost_usd for f in findings), Decimal("0"))
    top = sorted((f for f in findings if f.monthly_cost_usd > 0), key=lambda f: f.monthly_cost_usd, reverse=True)[:5]
    return {
        "total_findings": len(findings),
        "by_category": dict(sorted(by_category.items())),
        "estimated_monthly_savings_usd": str(_money(savings)),
        "top_items": [f"{f.resource_id} ({f.region}): {f.detail} ~ US$ {f.monthly_cost_usd}/mes" for f in top],
    }


def to_csv(findings: list[Finding]) -> str:
    buffer = io.StringIO()
    writer = csv.DictWriter(
        buffer,
        fieldnames=["category", "resource_type", "resource_id", "region", "detail", "monthly_cost_usd", "tags"],
    )
    writer.writeheader()
    for finding in findings:
        writer.writerow(finding.as_row())
    return buffer.getvalue()


def format_message(summary: dict[str, Any], report_uri: str) -> str:
    lines = [
        "Informe semanal de higiene de costes",
        "",
        f"Hallazgos: {summary['total_findings']}",
        f"Ahorro mensual estimado: US$ {summary['estimated_monthly_savings_usd']}",
        "",
    ]
    lines += [f"  - {category}: {count}" for category, count in summary["by_category"].items()]
    if summary["top_items"]:
        lines += ["", "Mayores oportunidades:"] + [f"  - {item}" for item in summary["top_items"]]
    lines += ["", f"Informe completo: {report_uri}"]
    return "\n".join(lines)


def handler(event: dict[str, Any] | None = None, context: Any = None) -> dict[str, Any]:
    settings = Settings.from_env()
    regions = [r.strip() for r in os.environ.get("SCAN_REGIONS", os.environ["AWS_REGION"]).split(",") if r.strip()]
    bucket = os.environ["REPORT_BUCKET"]
    topic_arn = os.environ.get("TOPIC_ARN")

    findings: list[Finding] = []
    tagged = 0
    for region in regions:
        scanner = Scanner(boto3.client("ec2", region_name=region), region, settings)
        region_findings = scanner.scan()
        if settings.tag_candidates:
            tagged += scanner.tag_candidates(region_findings)
        findings.extend(region_findings)

    summary = summarize(findings)
    summary["tagged_for_review"] = tagged

    key_prefix = f"reports/{datetime.now(UTC):%Y/%m/%d}"
    s3 = boto3.client("s3")
    s3.put_object(
        Bucket=bucket, Key=f"{key_prefix}/findings.csv", Body=to_csv(findings).encode(), ContentType="text/csv"
    )
    s3.put_object(
        Bucket=bucket,
        Key=f"{key_prefix}/summary.json",
        Body=json.dumps(summary, ensure_ascii=False, indent=2).encode(),
        ContentType="application/json",
    )
    report_uri = f"s3://{bucket}/{key_prefix}/findings.csv"

    if topic_arn and findings:
        savings = summary["estimated_monthly_savings_usd"]
        boto3.client("sns").publish(
            TopicArn=topic_arn,
            Subject=f"FinOps: {summary['total_findings']} hallazgos, ~US$ {savings}/mes",
            Message=format_message(summary, report_uri),
        )

    logger.info(json.dumps({"message": "scan complete", **summary}, ensure_ascii=False))
    return {**summary, "report": report_uri}
