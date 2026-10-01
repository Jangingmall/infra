#!/usr/bin/env python3
"""Stage EBS snapshot drill. Live changes require a separate execution approval."""

# 가정: 원본은 ext4 단일 PGDATA EBS이고, PostgreSQL이 정상 종료된 뒤 분리된다.
# 가정: 현행 CNPG 이미지의 PostgreSQL 실행 파일은 /usr/lib/postgresql/<major>/bin/ 이다.

import argparse
import datetime as dt
import hashlib
import json
import re
import subprocess
import sys
import time
from pathlib import Path


UTC = dt.timezone.utc
ID = re.compile(r"^[a-z0-9][a-z0-9-]{2,45}$")
K8S_NAME = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
NODE_NAME = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$")
TABLE = re.compile(r"^[a-z_][a-z_0-9]*\.[a-z_][a-z_0-9]*$")
AWS_VOLUME = re.compile(r"^vol-[0-9a-f]+$")


def now():
    return dt.datetime.now(UTC).isoformat(timespec="seconds")


def instant(value):
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("UTC offset required for evidence timestamps")
    return parsed.astimezone(UTC)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_json(path):
    def unique_pairs(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, f"duplicate JSON key: {key}")
            value[key] = item
        return value

    with open(path, encoding="utf-8") as handle:
        return json.load(handle, object_pairs_hook=unique_pairs)


def save_json(path, data):
    target = Path(path)
    temp = target.with_name(target.name + ".tmp")
    temp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temp.replace(target)


def config(path):
    c = load_json(path)
    for key in ("accountId", "clusterName", "approvedStageClusterArn", "stageEnvironmentTagKey",
                "stageEnvironmentTagValue", "testId", "sourceVolumeId", "namespace",
                "nodeName", "serviceDbName", "image", "dataDir", "mountPath",
                "database", "fsType"):
        require(isinstance(c.get(key), str) and c[key].strip(), f"config.{key} required")
    require(re.fullmatch(r"\d{12}", c["accountId"]), "12-digit accountId required")
    require(c.get("region") == "ap-northeast-2", "Stage region must be ap-northeast-2")
    require(ID.fullmatch(c["testId"]), "invalid testId")
    require(c["testId"].startswith("ebs-drill-"), "testId must start ebs-drill-")
    require(AWS_VOLUME.fullmatch(c["sourceVolumeId"]), "invalid sourceVolumeId")
    for key in ("namespace", "serviceDbName"):
        require(K8S_NAME.fullmatch(c[key]), f"invalid {key}")
    require(len(c["nodeName"]) <= 253 and all(len(label) <= 63 for label in c["nodeName"].split("."))
            and NODE_NAME.fullmatch(c["nodeName"]), "invalid nodeName")
    expected_arn = f"arn:aws:eks:{c['region']}:{c['accountId']}:cluster/{c['clusterName']}"
    require(c["approvedStageClusterArn"] == expected_arn, "approved Stage cluster ARN mismatch")
    require(c["stageEnvironmentTagValue"].lower() in ("stage", "staging"),
            "Stage environment tag value required")
    require(c["serviceDbName"] != c["testId"], "service/test name collision")
    require(isinstance(c.get("sourceTags"), dict) and c["sourceTags"], "sourceTags required")
    require(isinstance(c.get("pgMajor"), int) and 10 <= c["pgMajor"] <= 20,
            "review source PostgreSQL major version")
    require(c["dataDir"].startswith(c["mountPath"] + "/"), "dataDir must be below mountPath")
    for key in ("dataDir", "mountPath"):
        require(re.fullmatch(r"/[A-Za-z0-9_./-]+", c[key]) and ".." not in c[key], f"invalid {key}")
    require(c["fsType"] in ("ext4", "xfs"), "fsType must match original PV")
    require(isinstance(c.get("runAsUser"), int) and c["runAsUser"] > 0, "runAsUser required")
    require(isinstance(c.get("runAsGroup"), int) and c["runAsGroup"] > 0, "runAsGroup required")
    require(c.get("cpuRequest") in ("250m", "300m", "400m", "500m"), "review cpuRequest")
    require(c.get("memoryRequest") in ("512Mi", "640Mi", "768Mi"), "review memoryRequest")
    counts = c.get("expectedCounts")
    require(isinstance(counts, dict) and counts, "snapshot-time expectedCounts required")
    for name, count in counts.items():
        require(TABLE.fullmatch(name) and isinstance(count, int) and count >= 0, "invalid table count")
    return c


def evidence(path, c, max_age_hours=None):
    e = load_json(path)
    require(e.get("volumeId") == c["sourceVolumeId"], "shutdown evidence volume mismatch")
    require(e.get("pgMajor") == c["pgMajor"] and e.get("dataDir") == c["dataDir"],
            "shutdown evidence PostgreSQL mismatch")
    require(e.get("image") == c["image"] and e.get("fsType") == c["fsType"],
            "shutdown evidence image/filesystem mismatch")
    require(e.get("database") == c["database"], "source database evidence mismatch")
    tables = e.get("sourceTables")
    counts = e.get("sourceCounts")
    require(isinstance(tables, list) and tables
            and all(isinstance(name, str) and TABLE.fullmatch(name) for name in tables)
            and len(tables) == len(set(tables)),
            "complete source table inventory required")
    require(set(tables) == set(c["expectedCounts"]), "source table inventory/config mismatch")
    require(counts == c["expectedCounts"], "source counts/config mismatch")
    require(e.get("pgControlState") == "shut down", "pg_controldata must say shut down")
    require(e.get("writesFenced") is True, "writes must be fenced before shutdown")
    counts_at = instant(e["countsAt"])
    stopped_at = instant(e["stoppedAt"])
    observed_at = instant(e["pgControlObservedAt"])
    require(counts_at <= stopped_at <= observed_at <= dt.datetime.now(UTC),
            "shutdown/counts evidence order invalid")
    if max_age_hours is not None:
        require(dt.datetime.now(UTC) - observed_at <= dt.timedelta(hours=max_age_hours),
                "shutdown evidence is stale; recheck PGDATA")
    return e


def baseline_digest(e):
    baseline = {key: e[key] for key in ("volumeId", "database", "countsAt", "sourceTables", "sourceCounts")}
    canonical = json.dumps(baseline, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def require_baseline(state, e):
    require(state.get("baselineSha256") == baseline_digest(e),
            "snapshot-time source table/count baseline changed or is missing")


def table_inventory_matches(restored_tables, source_tables):
    return len(restored_tables) == len(source_tables) and set(restored_tables) == set(source_tables)


def kubectl(*arguments):
    result = subprocess.run(["kubectl", *arguments], capture_output=True, text=True, timeout=45)
    require(result.returncode == 0, f"kubectl {' '.join(arguments[:2])} failed")
    return result.stdout


def kube_json(*arguments):
    return json.loads(kubectl(*arguments, "-o", "json"))


def aws_clients(c):
    try:
        import boto3
    except ImportError as exc:
        raise RuntimeError("boto3 is required for live AWS checks") from exc
    session = boto3.Session(region_name=c["region"])
    sts = session.client("sts")
    ec2 = session.client("ec2")
    eks = session.client("eks")
    require(sts.get_caller_identity()["Account"] == c["accountId"], "AWS account mismatch")
    cluster = eks.describe_cluster(name=c["clusterName"])["cluster"]
    require(cluster["arn"].split(":")[3:5] == [c["region"], c["accountId"]],
            "EKS cluster account/region mismatch")
    require(cluster["arn"] == c["approvedStageClusterArn"], "unapproved EKS cluster ARN")
    tag = (cluster.get("tags") or {}).get(c["stageEnvironmentTagKey"], "")
    require(tag.lower() == c["stageEnvironmentTagValue"].lower(), "EKS cluster is not tagged Stage")
    require(cluster["status"] == "ACTIVE", "EKS cluster is not ACTIVE")
    context = kube_json("config", "view", "--minify")
    server = context["clusters"][0]["cluster"]["server"]
    require(server == cluster["endpoint"], "kubectl context is not the selected EKS cluster")
    return ec2


def resource_tags(resource):
    return {tag["Key"]: tag["Value"] for tag in resource.get("Tags", [])}


def source_volume(ec2, c):
    volumes = ec2.describe_volumes(VolumeIds=[c["sourceVolumeId"]])["Volumes"]
    require(len(volumes) == 1, "source EBS missing")
    volume = volumes[0]
    require(volume["Size"] == 20 and volume["Encrypted"], "source EBS must be encrypted 20GiB")
    require(volume["State"] == "available" and not volume["Attachments"],
            "source EBS must be detached and available")
    actual = resource_tags(volume)
    for key, value in c["sourceTags"].items():
        require(actual.get(key) == value, f"source EBS tag mismatch: {key}")
    return volume


def cpu_m(value):
    s = str(value)
    return int(s[:-1]) if s.endswith("m") else int(float(s) * 1000)


def bytes_m(value):
    s = str(value)
    for suffix, multiplier in (("Ki", 1024), ("Mi", 1024**2), ("Gi", 1024**3), ("Ti", 1024**4)):
        if s.endswith(suffix):
            return int(float(s[:-len(suffix)]) * multiplier)
    return int(s)


def pod_requests(pod):
    spec = pod["spec"]
    def total(containers, key, converter):
        return sum(converter(item.get("resources", {}).get("requests", {}).get(key, "0"))
                   for item in containers)
    regular = spec.get("containers", [])
    init = spec.get("initContainers", [])
    overhead = spec.get("overhead", {})
    result = []
    for key, converter in (("cpu", cpu_m), ("memory", bytes_m)):
        running_sidecars = 0
        peak = 0
        for item in init:
            request = converter(item.get("resources", {}).get("requests", {}).get(key, "0"))
            if item.get("restartPolicy") == "Always":
                running_sidecars += request
            else:
                peak = max(peak, running_sidecars + request)
        peak = max(peak, running_sidecars + total(regular, key, converter))
        result.append(peak + converter(overhead.get(key, "0")))
    return tuple(result)


def node_check(ec2, c, source_az):
    node = kube_json("get", "node", c["nodeName"])
    labels = node["metadata"]["labels"]
    require(labels.get("topology.kubernetes.io/zone") == source_az, "node/source AZ mismatch")
    require(labels.get("kubernetes.io/hostname") == c["nodeName"], "node hostname label mismatch")
    require(not node["spec"].get("taints"), "node taint requires review")
    require(not node["spec"].get("unschedulable"), "node is cordoned")
    require(any(x["type"] == "Ready" and x["status"] == "True"
                for x in node["status"]["conditions"]), "node is not Ready")
    provider_id = node["spec"].get("providerID", "")
    instance_id = provider_id.rsplit("/", 1)[-1]
    require(re.fullmatch(r"i-[0-9a-f]+", instance_id), "node EC2 ID unavailable")
    instance = ec2.describe_instances(InstanceIds=[instance_id])["Reservations"][0]["Instances"][0]
    require(instance["Placement"]["AvailabilityZone"] == source_az, "EC2 node AZ mismatch")
    pods = kube_json("get", "pods", "-A", "--field-selector", f"spec.nodeName={c['nodeName']}")["items"]
    active = [pod for pod in pods if pod["status"]["phase"] not in ("Succeeded", "Failed")]
    used = [0, 0]
    for pod in active:
        request = pod_requests(pod)
        used[0] += request[0]
        used[1] += request[1]
    alloc = node["status"]["allocatable"]
    require(used[0] + cpu_m(c["cpuRequest"]) <= cpu_m(alloc["cpu"]), "insufficient node CPU requests")
    require(used[1] + bytes_m(c["memoryRequest"]) <= bytes_m(alloc["memory"]),
            "insufficient node memory requests")
    require(len(active) + 1 <= int(alloc["pods"]), "insufficient Pod slots")
    csi = kube_json("get", "csinode", c["nodeName"])
    driver = next((d for d in csi["spec"]["drivers"] if d["name"] == "ebs.csi.aws.com"), None)
    require(driver and driver.get("allocatable", {}).get("count"), "EBS CSI attachment limit unavailable")
    attachments = kube_json("get", "volumeattachments")["items"]
    attached = sum(1 for item in attachments if item["spec"]["nodeName"] == c["nodeName"]
                   and item["spec"]["attacher"] == "ebs.csi.aws.com")
    require(attached + 1 <= int(driver["allocatable"]["count"]), "no EBS attachment slot")
    return {"node": c["nodeName"], "az": source_az, "cpuFreeM": cpu_m(alloc["cpu"]) - used[0],
            "memoryFreeMi": (bytes_m(alloc["memory"]) - used[1]) // 1024**2,
            "podFree": int(alloc["pods"]) - len(active),
            "ebsAttachmentFree": int(driver["allocatable"]["count"]) - attached}


def kubernetes_safety(c):
    service = kube_json("get", "clusters.postgresql.cnpg.io", c["serviceDbName"], "-n", c["namespace"])
    require(service["metadata"]["name"] == c["serviceDbName"], "service DB missing")
    service_pvcs = kube_json("get", "pvc", "-n", c["namespace"], "-l",
                             f"cnpg.io/cluster={c['serviceDbName']}")["items"]
    require(service_pvcs, "service PVC ownership could not be confirmed")
    protected = {p["metadata"]["name"] for p in service_pvcs}
    require(c["testId"] not in protected, "test PVC is a service PVC")
    pv_items = kube_json("get", "pv")["items"]
    active_claims = {(p["metadata"]["namespace"], p["metadata"]["name"])
                     for p in kube_json("get", "pvc", "-A")["items"]}
    service_pv_names = {p["spec"].get("volumeName") for p in service_pvcs}
    for pv in pv_items:
        handle = pv["spec"].get("csi", {}).get("volumeHandle")
        claim = pv["spec"].get("claimRef", {})
        if handle == c["sourceVolumeId"]:
            require(pv["metadata"]["name"] not in service_pv_names and claim.get("name") not in protected,
                    "source EBS is a service PV/PVC")
            require(pv["status"]["phase"] in ("Released", "Available"), "source PV is still bound")
            require((claim.get("namespace"), claim.get("name")) not in active_claims,
                    "source PV still has a live PVC")
    existing_pv = next((pv for pv in pv_items if pv["metadata"]["name"] == c["testId"]), None)
    if existing_pv:
        require(existing_pv["metadata"].get("labels", {}).get("drill-id") == c["testId"],
                "PV name collision")
    for kind in ("pod", "pvc", "networkpolicy"):
        raw = kubectl("get", kind, c["testId"], "-n", c["namespace"], "--ignore-not-found", "-o", "json")
        if raw.strip():
            require(json.loads(raw)["metadata"].get("labels", {}).get("drill-id") == c["testId"],
                    f"{kind} name collision")


def preflight(c, e):
    ec2 = aws_clients(c)
    source = source_volume(ec2, c)
    kubernetes_safety(c)
    node = node_check(ec2, c, source["AvailabilityZone"])
    require(e["volumeId"] == source["VolumeId"], "evidence/source mismatch")
    return ec2, source, node


def find_tagged(ec2, kind, c):
    filters = [{"Name": "tag:DrillId", "Values": [c["testId"]]},
               {"Name": "tag:Purpose", "Values": ["stage-ebs-snapshot-restore"]}]
    if kind == "snapshot":
        resources = ec2.describe_snapshots(OwnerIds=["self"], Filters=filters)["Snapshots"]
    else:
        resources = ec2.describe_volumes(Filters=filters)["Volumes"]
    require(len(resources) <= 1, f"multiple tagged {kind}s; stop")
    return resources[0] if resources else None


def tags(c, extra):
    return [{"Key": key, "Value": value} for key, value in
            {"DrillId": c["testId"], "Purpose": "stage-ebs-snapshot-restore", **extra}.items()]


def snapshot(c, e, state_path):
    evidence_value = evidence(e, c)
    ec2, source, node = preflight(c, evidence_value)
    state = load_json(state_path) if Path(state_path).exists() else {"testId": c["testId"]}
    require(state.get("testId") == c["testId"], "state testId mismatch")
    existing = find_tagged(ec2, "snapshot", c)
    if existing:
        require_baseline(state, evidence_value)
        require(existing["VolumeId"] == source["VolumeId"] and existing["Encrypted"]
                and existing["VolumeSize"] == 20 and existing.get("StorageTier", "standard") == "standard",
                "tagged snapshot is not this encrypted source")
        require(state.get("snapshotId") in (None, existing["SnapshotId"]), "state snapshot mismatch")
        require(state.get("snapshotStartedAt"), "existing snapshot has no timing record; stop")
        snap_id = existing["SnapshotId"]
    else:
        require(state.get("baselineSha256") in (None, baseline_digest(evidence_value)),
                "snapshot-time baseline changed before creation")
        require(dt.datetime.now(UTC) - instant(evidence_value["pgControlObservedAt"]) <= dt.timedelta(hours=1),
                "shutdown evidence is stale; recheck PGDATA")
        require(not state.get("snapshotId"), "state references missing snapshot; stop")
        state["snapshotStartedAt"] = now()
        state["baselineSha256"] = baseline_digest(evidence_value)
        created = ec2.create_snapshot(VolumeId=source["VolumeId"],
                                     Description=f"Stage EBS drill {c['testId']}",
                                     TagSpecifications=[{"ResourceType": "snapshot", "Tags": tags(c, {"SourceVolume": source["VolumeId"]})}])
        snap_id = created["SnapshotId"]
        state["snapshotId"] = snap_id
        save_json(state_path, state)
    ec2.get_waiter("snapshot_completed").wait(SnapshotIds=[snap_id],
                                                WaiterConfig={"Delay": 15, "MaxAttempts": 480})
    actual = ec2.describe_snapshots(SnapshotIds=[snap_id])["Snapshots"][0]
    require(actual["State"] == "completed" and actual["Encrypted"], "snapshot not complete/encrypted")
    state.setdefault("snapshotCompletedAt", now())
    state["sourceVolumeId"] = source["VolumeId"]
    state["az"] = node["az"]
    save_json(state_path, state)
    print(json.dumps({"snapshotId": snap_id, "state": "completed", "snapshotStartedAt": state["snapshotStartedAt"],
                      "snapshotCompletedAt": state["snapshotCompletedAt"]}))


def create_volume(c, e, state_path):
    evidence_value = evidence(e, c)
    ec2, source, node = preflight(c, evidence_value)
    state = load_json(state_path)
    require_baseline(state, evidence_value)
    require(state.get("testId") == c["testId"] and state.get("sourceVolumeId") == source["VolumeId"],
            "snapshot state/source mismatch")
    snap_id = state["snapshotId"]
    snap = ec2.describe_snapshots(SnapshotIds=[snap_id])["Snapshots"][0]
    require(snap["State"] == "completed" and snap["Encrypted"] and snap["VolumeId"] == source["VolumeId"],
            "snapshot identity/completion mismatch")
    require(snap.get("StorageTier", "standard") == "standard", "archived snapshot forbidden")
    fsr = ec2.describe_fast_snapshot_restores(Filters=[{"Name": "snapshot-id", "Values": [snap_id]}])
    require(not any(item.get("State") == "enabled" and item.get("AvailabilityZone") == node["az"]
                    for item in fsr["FastSnapshotRestores"]), "FSR enabled; stop")
    existing = find_tagged(ec2, "volume", c)
    if existing:
        volume = existing
        require(state.get("volumeId") == volume["VolumeId"] and state.get("volumeCreateRequestedAt"),
                "existing volume has no matching timing record; stop")
    else:
        require(not state.get("volumeId"), "state references missing volume; stop")
        state["volumeCreateRequestedAt"] = now()
        volume = ec2.create_volume(AvailabilityZone=node["az"], SnapshotId=snap_id, Size=20,
                                   VolumeType="gp3", Encrypted=True,
                                   TagSpecifications=[{"ResourceType": "volume", "Tags": tags(c, {"SnapshotId": snap_id})}])
        state["volumeId"] = volume["VolumeId"]
        save_json(state_path, state)
    require(volume["SnapshotId"] == snap_id and volume["Size"] == 20 and volume["VolumeType"] == "gp3"
            and volume["Encrypted"] and volume["AvailabilityZone"] == node["az"], "test volume mismatch")
    ec2.get_waiter("volume_available").wait(VolumeIds=[volume["VolumeId"]],
                                              WaiterConfig={"Delay": 10, "MaxAttempts": 180})
    actual = ec2.describe_volumes(VolumeIds=[volume["VolumeId"]])["Volumes"][0]
    require(actual["State"] == "available" and not actual["Attachments"], "new EBS not available")
    state.setdefault("volumeAvailableAt", now())
    save_json(state_path, state)
    print(json.dumps({"volumeId": volume["VolumeId"], "state": "available",
                      "volumeCreateRequestedAt": state["volumeCreateRequestedAt"],
                      "volumeAvailableAt": state["volumeAvailableAt"]}))


def manifest(c, state):
    name = c["testId"]
    labels = {"app": name, "drill-id": name}
    namespace = c["namespace"]
    pv = {"apiVersion": "v1", "kind": "PersistentVolume", "metadata": {"name": name, "labels": labels},
          "spec": {"capacity": {"storage": "20Gi"}, "accessModes": ["ReadWriteOnce"],
                   "persistentVolumeReclaimPolicy": "Retain", "storageClassName": "",
                   "volumeMode": "Filesystem", "csi": {"driver": "ebs.csi.aws.com",
                   "volumeHandle": state["volumeId"], "fsType": c["fsType"]},
                   "nodeAffinity": {"required": {"nodeSelectorTerms": [{"matchExpressions": [
                       {"key": "topology.kubernetes.io/zone", "operator": "In", "values": [state["az"]]}]}]}}}}
    pvc = {"apiVersion": "v1", "kind": "PersistentVolumeClaim",
           "metadata": {"name": name, "namespace": namespace, "labels": labels},
           "spec": {"accessModes": ["ReadWriteOnce"], "storageClassName": "", "volumeName": name,
                    "volumeMode": "Filesystem", "resources": {"requests": {"storage": "20Gi"}}}}
    startup = ("test \"$(cat \"$PGDATA/PG_VERSION\")\" = \"$PG_MAJOR\"; "
               "\"/usr/lib/postgresql/$PG_MAJOR/bin/pg_controldata\" \"$PGDATA\" | "
               "grep -Eq '^Database cluster state: *shut down$'; "
               "test ! -e \"$PGDATA/recovery.signal\"; test ! -e \"$PGDATA/standby.signal\"; "
               "exec \"/usr/lib/postgresql/$PG_MAJOR/bin/postgres\" -D \"$PGDATA\" "
               "-c listen_addresses= -c archive_mode=off -c ssl=off "
               "-c unix_socket_directories=/tmp")
    container = {"name": "postgres", "image": c["image"], "imagePullPolicy": "IfNotPresent",
                 "command": ["/bin/sh", "-ec", startup],
                 "env": [{"name": "PGDATA", "value": c["dataDir"]},
                         {"name": "PG_MAJOR", "value": str(c["pgMajor"])},
                         {"name": "LC_ALL", "value": "C"}],
                 "resources": {"requests": {"cpu": c["cpuRequest"], "memory": c["memoryRequest"]},
                               "limits": {"memory": c["memoryRequest"]}},
                 "securityContext": {"allowPrivilegeEscalation": False,
                                     "capabilities": {"drop": ["ALL"]}},
                 "volumeMounts": [{"name": "data", "mountPath": c["mountPath"]}],
                 "readinessProbe": {"exec": {"command": [f"/usr/lib/postgresql/{c['pgMajor']}/bin/pg_isready",
                                                       "-h", "/tmp", "-d", c["database"]]},
                                    "periodSeconds": 5},
                 "startupProbe": {"exec": {"command": [f"/usr/lib/postgresql/{c['pgMajor']}/bin/pg_isready",
                                                     "-h", "/tmp", "-d", c["database"]]},
                                  "periodSeconds": 5, "failureThreshold": 120}}
    pod = {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": name, "namespace": namespace,
           "labels": labels}, "spec": {"restartPolicy": "Never", "automountServiceAccountToken": False,
           "nodeSelector": {"kubernetes.io/hostname": c["nodeName"]},
           "securityContext": {"runAsNonRoot": True, "runAsUser": c["runAsUser"],
                               "runAsGroup": c["runAsGroup"], "fsGroup": c["runAsGroup"],
                               "seccompProfile": {"type": "RuntimeDefault"}},
           "containers": [container], "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": name}}]}}
    policy = {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
              "metadata": {"name": name, "namespace": namespace, "labels": labels},
              "spec": {"podSelector": {"matchLabels": {"drill-id": name}},
                       "policyTypes": ["Ingress", "Egress"], "ingress": [], "egress": []}}
    return {"apiVersion": "v1", "kind": "List", "items": [pv, pvc, policy, pod]}


def render(c, e, state_path, output):
    evidence_value = evidence(e, c)
    ec2, _, node = preflight(c, evidence_value)
    state = load_json(state_path)
    require_baseline(state, evidence_value)
    require(state.get("testId") == c["testId"] and state.get("volumeAvailableAt"), "volume state missing")
    volume = ec2.describe_volumes(VolumeIds=[state["volumeId"]])["Volumes"][0]
    require(volume["State"] == "available" and not volume["Attachments"]
            and volume["AvailabilityZone"] == node["az"] and volume["SnapshotId"] == state["snapshotId"],
            "render volume identity/state mismatch")
    require(resource_tags(volume).get("DrillId") == c["testId"], "render volume tag mismatch")
    prior_pv = kubectl("get", "pv", c["testId"], "--ignore-not-found", "-o", "json")
    if prior_pv.strip():
        require(json.loads(prior_pv)["spec"].get("csi", {}).get("volumeHandle") == state["volumeId"],
                "existing test PV points to another EBS")
    prior_pvc = kubectl("get", "pvc", c["testId"], "-n", c["namespace"],
                        "--ignore-not-found", "-o", "json")
    if prior_pvc.strip():
        require(json.loads(prior_pvc)["spec"].get("volumeName") == c["testId"],
                "existing test PVC points to another PV")
    Path(output).write_text(json.dumps(manifest(c, state), indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"manifest": str(output), "volumeId": state["volumeId"], "resources": 4}))


def observe(c, e, state_path, timeout_seconds):
    evidence_value = evidence(e, c)
    state = load_json(state_path)
    require_baseline(state, evidence_value)
    require(state.get("testId") == c["testId"] and state.get("volumeCreateRequestedAt")
            and state.get("volumeAvailableAt"), "timing state missing")
    ec2 = aws_clients(c)
    volume = ec2.describe_volumes(VolumeIds=[state["volumeId"]])["Volumes"][0]
    require(volume["VolumeId"] != c["sourceVolumeId"] and volume["SnapshotId"] == state["snapshotId"]
            and resource_tags(volume).get("DrillId") == c["testId"], "observed EBS identity mismatch")
    name = c["testId"]
    pv = kube_json("get", "pv", name)
    pvc = kube_json("get", "pvc", name, "-n", c["namespace"])
    require(pv["spec"].get("csi", {}).get("volumeHandle") == state["volumeId"]
            and pvc["spec"].get("volumeName") == name, "observed PV/PVC identity mismatch")
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        pod = kube_json("get", "pod", name, "-n", c["namespace"])
        require(pod["metadata"].get("labels", {}).get("drill-id") == name, "Pod identity mismatch")
        require(pod["spec"]["volumes"][0]["persistentVolumeClaim"]["claimName"] == name,
                "Pod PVC mismatch")
        if pod["status"]["phase"] == "Failed":
            raise ValueError("test Pod failed; inspect only test Pod events")
        ready = next((x for x in pod["status"].get("conditions", [])
                      if x["type"] == "Ready" and x["status"] == "True"), None)
        if ready:
            state.setdefault("dbReadyAt", ready["lastTransitionTime"])
            save_json(state_path, state)
            break
        time.sleep(5)
    else:
        raise TimeoutError("test Pod Ready timeout")
    psql = ["kubectl", "exec", "-n", c["namespace"], name, "--",
            f"/usr/lib/postgresql/{c['pgMajor']}/bin/psql", "-XAt", "-h", "/tmp",
            "-U", "postgres", "-d", c["database"]]
    while time.monotonic() < deadline:
        sql = subprocess.run([*psql, "-c", "SELECT 1"], capture_output=True, text=True, timeout=30)
        if sql.returncode == 0 and sql.stdout.strip() == "1":
            state.setdefault("sqlConnectedAt", now())
            save_json(state_path, state)
            break
        time.sleep(5)
    else:
        raise TimeoutError("local SQL connection timeout; no credentials printed")
    inventory_sql = ("SELECT n.nspname || '.' || c.relname "
                     "FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n "
                     "ON n.oid = c.relnamespace WHERE c.relkind IN ('r','p') "
                     "AND n.nspname NOT IN ('pg_catalog','information_schema') "
                     "AND n.nspname NOT LIKE 'pg_toast%' "
                     "AND n.nspname NOT LIKE 'pg_temp_%' "
                     "ORDER BY n.nspname, c.relname")
    inventory = subprocess.run([*psql, "-c", inventory_sql], capture_output=True, text=True, timeout=120)
    require(inventory.returncode == 0, "restored table inventory query failed")
    restored_tables = inventory.stdout.splitlines()
    source_tables = set(evidence_value["sourceTables"])
    list_match = table_inventory_matches(restored_tables, source_tables)
    state["tablesListedAt"] = now()
    state["tableListResult"] = "match" if list_match else "mismatch"
    save_json(state_path, state)
    require(list_match, "restored table inventory differs from snapshot-time source")
    mismatches = []
    for table, expected in sorted(evidence_value["sourceCounts"].items()):
        schema, name = table.split(".")
        query = f'SELECT count(*) FROM "{schema}"."{name}"'
        result = subprocess.run([*psql, "-c", query], capture_output=True, text=True, timeout=120)
        require(result.returncode == 0 and result.stdout.strip().isdigit(), "table count query failed")
        if int(result.stdout.strip()) != expected:
            mismatches.append(table)
    state["countsVerifiedAt"] = now()
    state["tableCountResult"] = "match" if not mismatches else "mismatch"
    state["tableCountChecked"] = len(c["expectedCounts"])
    state["mismatchedTableCount"] = len(mismatches)
    save_json(state_path, state)
    print(json.dumps({key: state[key] for key in ("volumeId", "volumeCreateRequestedAt",
                      "volumeAvailableAt", "dbReadyAt", "sqlConnectedAt", "tablesListedAt",
                      "tableListResult", "countsVerifiedAt", "tableCountResult",
                      "tableCountChecked", "mismatchedTableCount")}))
    require(not mismatches, "table row counts differ from snapshot-time source")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--evidence")
    parser.add_argument("--state")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("preflight", "snapshot", "create-volume", "render", "observe"):
        command = commands.add_parser(name)
        if name == "render":
            command.add_argument("--output", required=True)
        if name == "observe":
            command.add_argument("--timeout-seconds", type=int, default=1800)
    args = parser.parse_args()
    c = config(args.config)
    require(args.evidence, "--evidence required")
    require(args.state or args.command == "preflight", "--state required")
    if args.command == "preflight":
        _, source, node = preflight(c, evidence(args.evidence, c, max_age_hours=1))
        print(json.dumps({"result": "pass", "sourceVolumeId": source["VolumeId"], **node}))
    elif args.command == "snapshot":
        snapshot(c, args.evidence, args.state)
    elif args.command == "create-volume":
        create_volume(c, args.evidence, args.state)
    elif args.command == "render":
        render(c, args.evidence, args.state, args.output)
    else:
        observe(c, args.evidence, args.state, args.timeout_seconds)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, TimeoutError, KeyError, IndexError, OSError) as exc:
        print(f"STOP: {exc}", file=sys.stderr)
        sys.exit(2)
