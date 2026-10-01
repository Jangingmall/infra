#!/usr/bin/env python3
"""Stage HA drill — 노드 1대 종료 / CNPG primary 장애 시 자동 복구 시간 측정.

실제 변경(인스턴스 종료·Pod 삭제)은 --execute + 대상 이름 직접 입력 후에만 일어난다.
실행 전 파트장 승인과 디스코드 공지가 필요하다 (노드 종료는 보안 탐지 규칙에 걸리지 않음).

  # 0) 사전 점검만 — 아무것도 바꾸지 않음
  python3 scripts/ha_failover_drill.py node
  python3 scripts/ha_failover_drill.py cnpg

  # 1) 시험 A: app 노드 1대 종료 → 관리형 노드그룹 자동 교체
  python3 scripts/ha_failover_drill.py node --execute

  # 2) 시험 B (선택): CNPG primary Pod 삭제 → 자동 승격
  python3 scripts/ha_failover_drill.py cnpg --execute

결과: ha-results/<시험>-<UTC시각>/ 아래 summary.md · events.log · probe.csv · before/after 스냅샷.
summary.md 의 표를 HA 검증 보고서 §4·§5 에 그대로 붙인다.

필요: aws CLI(Infra-Admin SSO 로그인) · kubectl(staging kubeconfig) · Python 3.9+
"""

import argparse
import csv
import datetime as dt
import json
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

UTC = dt.timezone.utc
KST = dt.timezone(dt.timedelta(hours=9))

DEFAULTS = {
    "cluster": "jangin-staging-eks-cluster",
    "nodegroup": "jangin-staging-ng-app",
    "region": "ap-northeast-2",
    "health_url": "https://api.stg.midam.store/api/products",
    "db_url": "https://api.stg.midam.store/api/products",
    "cnpg_cluster": "jangingmall-postgres",
}
APP_LABEL = "workload-type=app"
BACKEND_SELECTOR = "app.kubernetes.io/name=backend"


# ------------------------------------------------------------------ 공통 도구
def now():
    return time.time()


def kst(ts):
    return dt.datetime.fromtimestamp(ts, KST).strftime("%H:%M:%S")


def run(cmd, check=True):
    """명령 실행 후 stdout 반환. 실패하면 stderr 를 그대로 보여주고 멈춘다."""
    p = subprocess.run(cmd, capture_output=True, text=True)
    if check and p.returncode != 0:
        sys.exit(f"[중단] 명령 실패: {' '.join(cmd)}\n{p.stderr.strip()}")
    return p.stdout


def kjson(*args):
    return json.loads(run(["kubectl", *args, "-o", "json"]))


class Log:
    def __init__(self, outdir):
        self.path = outdir / "events.log"
        self.fh = open(self.path, "a", encoding="utf-8")

    def __call__(self, msg):
        line = f"{kst(now())} KST  {msg}"
        print(line, flush=True)
        self.fh.write(line + "\n")
        self.fh.flush()


def snapshot(outdir, tag, namespaces):
    (outdir / f"{tag}-nodes.txt").write_text(
        run(["kubectl", "get", "nodes", "-L", "workload-type", "-o", "wide"], check=False))
    for ns in namespaces:
        (outdir / f"{tag}-pods-{ns}.txt").write_text(
            run(["kubectl", "get", "pods", "-n", ns, "-o", "wide"], check=False))


def confirm(expected, what):
    print(f"\n⚠️  {what}")
    print(f"   계속하려면 대상 이름을 그대로 입력하세요: {expected}")
    if input("> ").strip() != expected:
        sys.exit("[취소] 입력이 일치하지 않아 아무것도 바꾸지 않았습니다.")


# ------------------------------------------------------------------ 외부 가용성 측정기
class Prober(threading.Thread):
    """1초마다 URL 을 호출해 (시각, 상태코드, 지연) 을 기록한다. 실패는 code=0."""

    def __init__(self, url, interval=1.0, timeout=3.0):
        super().__init__(daemon=True)
        self.url, self.interval, self.timeout = url, interval, timeout
        self.rows, self._halt = [], threading.Event()

    def run(self):
        while not self._halt.is_set():
            t0 = now()
            try:
                with urllib.request.urlopen(self.url, timeout=self.timeout) as r:
                    code = r.status
            except urllib.error.HTTPError as e:
                code = e.code
            except Exception:
                code = 0
            self.rows.append((t0, code, round(now() - t0, 3)))
            self._halt.wait(max(0.0, self.interval - (now() - t0)))

    def stop(self):
        self._halt.set()
        self.join(timeout=5)

    def save(self, path):
        with open(path, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["epoch", "kst", "code", "latency_s"])
            for t, c, l in self.rows:
                w.writerow([f"{t:.3f}", kst(t), c, l])

    def stats(self, start, end):
        rows = [r for r in self.rows if start <= r[0] <= end]
        bad = [r for r in rows if not (200 <= r[1] < 400)]
        # 가장 긴 연속 실패 구간 = 사용자가 체감한 서비스 중단 시간
        longest, cur_start, prev_bad = 0.0, None, False
        for t, c, _ in rows:
            is_bad = not (200 <= c < 400)
            if is_bad and not prev_bad:
                cur_start = t
            if is_bad:
                longest = max(longest, t - cur_start + self.interval)
            prev_bad = is_bad
        return {"total": len(rows), "failed": len(bad), "longest_outage_s": round(longest, 1),
                "max_latency_s": max((r[2] for r in rows), default=0)}


# ------------------------------------------------------------------ 시험 A: 노드 종료
def node_ready(node):
    return any(c["type"] == "Ready" and c["status"] == "True" for c in node["status"]["conditions"])


def pod_ready(pod):
    return any(c["type"] == "Ready" and c["status"] == "True"
               for c in pod.get("status", {}).get("conditions", []))


def app_state():
    nodes = kjson("get", "nodes", "-l", APP_LABEL)["items"]
    pods = kjson("get", "pods", "-n", "app")["items"]
    backend = [p for p in pods if p["metadata"].get("labels", {}).get("app.kubernetes.io/name") == "backend"]
    return nodes, pods, backend


def drill_node(a, outdir, log):
    ng = json.loads(run(["aws", "eks", "describe-nodegroup", "--region", a.region,
                         "--cluster-name", a.cluster, "--nodegroup-name", a.nodegroup]))["nodegroup"]
    sc = ng["scalingConfig"]
    log(f"노드그룹 {a.nodegroup}: desired={sc['desiredSize']} min={sc['minSize']} max={sc['maxSize']}")

    nodes, pods, backend = app_state()
    ready_nodes = [n for n in nodes if node_ready(n)]
    log(f"app 노드 Ready {len(ready_nodes)}/{len(nodes)}: " + ", ".join(n["metadata"]["name"] for n in nodes))
    placement = {}
    for p in pods:
        placement.setdefault(p["spec"].get("nodeName", "-"), []).append(p["metadata"]["name"])
    for n, ps in placement.items():
        log(f"  {n}: {', '.join(ps)}")

    # --- 안전 조건: 하나라도 어기면 시험하지 않는다
    problems = []
    if sc["desiredSize"] < 2 or len(ready_nodes) < 2:
        problems.append("app 노드가 2대 Ready 가 아님 (노드가 내려가 있으면 시험 불가)")
    b_ready = [p for p in backend if pod_ready(p)]
    if len(b_ready) < 2 or len({p["spec"]["nodeName"] for p in b_ready}) < 2:
        problems.append("backend Pod 2개가 서로 다른 노드에서 Ready 가 아님 → 노드 1대 종료 시 전면 중단")
    redis_node = next((p["spec"].get("nodeName") for p in pods if p["metadata"]["name"] == "redis-0"), None)

    target = a.target_node
    if not target:
        cands = [n["metadata"]["name"] for n in ready_nodes if n["metadata"]["name"] != redis_node]
        target = cands[0] if cands else None
    if not target:
        problems.append("redis-0 이 없는 app 노드를 찾지 못함 → --target-node 로 직접 지정")
    if problems:
        for p in problems:
            log(f"🔴 {p}")
        sys.exit("[중단] 사전 점검 실패")

    node_obj = next(n for n in nodes if n["metadata"]["name"] == target)
    instance_id = node_obj["spec"]["providerID"].rsplit("/", 1)[-1]
    log(f"대상: {target} ({instance_id})" + ("  ⚠️ redis-0 동거 — 세션 저장소도 함께 중단됨" if target == redis_node else ""))
    snapshot(outdir, "before", ["app"])

    if not a.execute:
        log("✅ 사전 점검 통과 (--execute 없이 실행 → 여기서 종료, 변경 없음)")
        return None

    confirm(instance_id, f"EC2 인스턴스 {instance_id} 를 종료합니다 (staging app 노드 1대).")
    prober = Prober(a.health_url)
    prober.start()
    log(f"가용성 측정 시작: {a.health_url} (1초 간격) — 기준선 {a.baseline}초")
    time.sleep(a.baseline)

    marks = {}
    t0 = now()
    marks["T0 인스턴스 종료 요청"] = t0
    run(["aws", "ec2", "terminate-instances", "--region", a.region, "--instance-ids", instance_id])
    log(f"T0 terminate-instances {instance_id}")

    original = {n["metadata"]["name"] for n in nodes}
    dropped = False
    while now() - t0 < a.timeout:
        time.sleep(3)
        try:
            nodes, pods, backend = app_state()
        except SystemExit:
            continue  # API 일시 오류는 다음 주기에 재시도
        names = {n["metadata"]["name"]: n for n in nodes}
        tgt = names.get(target)

        def mark(key, cond):
            if cond and key not in marks:
                marks[key] = now()
                log(f"{key}  (+{marks[key] - t0:.0f}s)")

        mark("T1 대상 노드 NotReady 감지", tgt is None or not node_ready(tgt))
        mark("T2 대상 노드 객체 삭제", tgt is None)
        new = [n for k, n in names.items() if k not in original]
        mark("T3 교체 노드 등록", bool(new))
        mark("T4 교체 노드 Ready", any(node_ready(n) for n in new))
        rb = sum(1 for p in backend if pod_ready(p))
        if rb < 2:
            dropped = True
            mark("T5a backend Ready 1개로 감소", True)
        mark("T5 backend Ready 2/2 복구", dropped and rb >= 2)
        all_ok = all(pod_ready(p) or p["status"].get("phase") == "Succeeded" for p in pods)
        mark("T6 app 네임스페이스 전체 Ready", "T4 교체 노드 Ready" in marks and dropped and all_ok)
        if "T6 app 네임스페이스 전체 Ready" in marks:
            break
    else:
        log("🟡 제한 시간 초과 — 기록된 지점까지만 요약합니다")

    time.sleep(a.tail)
    prober.stop()
    t_end = now()
    snapshot(outdir, "after", ["app"])
    prober.save(outdir / "probe.csv")
    return {"title": "시험 A — app 노드 1대 종료", "target": f"{target} ({instance_id})",
            "t0": t0, "marks": marks, "probe": prober.stats(t0, t_end), "url": a.health_url}


# ------------------------------------------------------------------ 시험 B: CNPG primary 장애
def cnpg_state(a):
    c = kjson("get", "clusters.postgresql.cnpg.io", a.cnpg_cluster, "-n", "database")
    return c.get("status", {})


def drill_cnpg(a, outdir, log):
    st = cnpg_state(a)
    primary, ready = st.get("currentPrimary"), st.get("readyInstances", 0)
    log(f"CNPG {a.cnpg_cluster}: primary={primary} readyInstances={ready}/{st.get('instances')}")
    pods = kjson("get", "pods", "-n", "database", "-l", f"cnpg.io/cluster={a.cnpg_cluster}")["items"]
    for p in pods:
        log(f"  {p['metadata']['name']}  node={p['spec'].get('nodeName')}  ready={pod_ready(p)}")
    if ready < 3 or not primary:
        sys.exit("[중단] 3/3 Ready 가 아님 — 장애 시험 전에 정상 상태여야 합니다")
    snapshot(outdir, "before", ["database"])
    if not a.execute:
        log("✅ 사전 점검 통과 (--execute 없이 실행 → 여기서 종료, 변경 없음)")
        return None

    confirm(primary, f"CNPG primary Pod {primary} 를 삭제합니다 (비동기 복제 — 직전 커밋 일부 유실 가능).")
    prober = Prober(a.db_url)
    prober.start()
    log(f"가용성 측정 시작: {a.db_url} (DB 조회 API, 1초 간격) — 기준선 {a.baseline}초")
    time.sleep(a.baseline)

    marks = {}
    t0 = now()
    marks["T0 primary Pod 삭제"] = t0
    run(["kubectl", "delete", "pod", primary, "-n", "database", "--wait=false"])
    log(f"T0 delete pod {primary}")
    while now() - t0 < a.timeout:
        time.sleep(2)
        try:
            st = cnpg_state(a)
        except SystemExit:
            continue
        cur = st.get("currentPrimary")
        if cur and cur != primary and "T1 새 primary 승격" not in marks:
            marks["T1 새 primary 승격"] = now()
            log(f"T1 새 primary = {cur}  (+{marks['T1 새 primary 승격'] - t0:.0f}s)")
        if "T1 새 primary 승격" in marks and st.get("readyInstances", 0) >= 3:
            marks["T2 3/3 Ready 복구 (옛 primary 는 replica 로 재합류)"] = now()
            log(f"T2 readyInstances 3/3  (+{now() - t0:.0f}s)")
            break
    else:
        log("🟡 제한 시간 초과 — 기록된 지점까지만 요약합니다")

    time.sleep(a.tail)
    prober.stop()
    t_end = now()
    snapshot(outdir, "after", ["database"])
    prober.save(outdir / "probe.csv")
    return {"title": "시험 B — CNPG primary Pod 장애", "target": primary,
            "t0": t0, "marks": marks, "probe": prober.stats(t0, t_end), "url": a.db_url}


# ------------------------------------------------------------------ 요약
def write_summary(res, outdir, log):
    lines = [f"## {res['title']}", "",
             f"- 대상: `{res['target']}`",
             f"- 시작(T0): {kst(res['t0'])} KST", "",
             "| 지점 | 시각 (KST) | T0 대비 |", "| --- | --- | --- |"]
    for k, v in sorted(res["marks"].items(), key=lambda kv: kv[1]):
        lines.append(f"| {k} | {kst(v)} | +{v - res['t0']:.0f}초 |")
    p = res["probe"]
    lines += ["", f"**외부 가용성** — `{res['url']}` 1초 간격 호출", "",
              "| 항목 | 값 |", "| --- | --- |",
              f"| 호출 수 (T0 이후) | {p['total']} |",
              f"| 실패 수 (5xx·타임아웃·연결 실패) | {p['failed']} |",
              f"| 가장 긴 연속 실패 = **체감 중단 시간** | **{p['longest_outage_s']}초** |",
              f"| 최대 응답 지연 | {p['max_latency_s']}초 |", "",
              "> 시각은 실행 PC 시계 기준. probe.csv · events.log 가 원본 근거입니다."]
    (outdir / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    log(f"요약 저장: {outdir / 'summary.md'}")
    print("\n" + "\n".join(lines))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("drill", choices=["node", "cnpg"], help="node = 시험 A, cnpg = 시험 B")
    ap.add_argument("--execute", action="store_true", help="실제로 종료/삭제한다 (없으면 사전 점검만)")
    ap.add_argument("--target-node", help="시험 A 대상 노드 이름 (기본: redis-0 이 없는 app 노드)")
    ap.add_argument("--timeout", type=int, default=1200, help="최대 대기 초 (기본 1200 = 20분)")
    ap.add_argument("--baseline", type=int, default=30, help="T0 전 정상 구간 측정 초")
    ap.add_argument("--tail", type=int, default=60, help="복구 후 추가 측정 초")
    ap.add_argument("--out", default="ha-results")
    for k, v in DEFAULTS.items():
        ap.add_argument("--" + k.replace("_", "-"), default=v, dest=k)
    a = ap.parse_args()

    ctx = run(["kubectl", "config", "current-context"]).strip()
    if "staging" not in ctx:
        sys.exit(f"[중단] 현재 kubectl 컨텍스트가 staging 이 아닙니다: {ctx}")
    who = json.loads(run(["aws", "sts", "get-caller-identity"]))["Arn"]

    stamp = dt.datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    outdir = Path(a.out) / f"{a.drill}-{stamp}"
    outdir.mkdir(parents=True, exist_ok=True)
    log = Log(outdir)
    log(f"실행자 {who.split('/')[-2] if '/' in who else who} · 컨텍스트 {ctx} · 모드 {'EXECUTE' if a.execute else '점검만'}")

    res = drill_node(a, outdir, log) if a.drill == "node" else drill_cnpg(a, outdir, log)
    if res:
        write_summary(res, outdir, log)


if __name__ == "__main__":
    main()
