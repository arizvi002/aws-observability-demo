import json
import logging
import time

import boto3
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

# ── JSON logger ──────────────────────────────────────────────────────────────

class JsonFormatter(logging.Formatter):
    def format(self, record):
        msg = record.getMessage()
        try:
            body = json.loads(msg) if msg.startswith("{") else {"message": msg}
        except (ValueError, TypeError):
            body = {"message": str(msg)}
        entry = {
            "timestamp": self.formatTime(record, self.datefmt),
            "level": record.levelname,
            "logger": record.name,
            **body,
        }
        if record.exc_info:
            entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(entry)


_handler = logging.StreamHandler()
_handler.setFormatter(JsonFormatter())
logger = logging.getLogger("api")
logger.addHandler(_handler)
logger.setLevel(logging.INFO)

# ── CloudWatch metrics ────────────────────────────────────────────────────────

CW_NAMESPACE = "CSG/API"
_cw = boto3.client("cloudwatch", region_name="us-west-2")


def put_metric(name: str, value: float, unit: str = "Count") -> None:
    try:
        _cw.put_metric_data(
            Namespace=CW_NAMESPACE,
            MetricData=[{"MetricName": name, "Value": value, "Unit": unit}],
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning(json.dumps({"message": f"metric publish failed", "metric": name, "error": str(exc)}))


# ── App ───────────────────────────────────────────────────────────────────────

app = FastAPI(title="AWS Observability Demo")


@app.middleware("http")
async def observability_middleware(request: Request, call_next):
    t0 = time.perf_counter()
    response = await call_next(request)
    latency_ms = (time.perf_counter() - t0) * 1000

    put_metric("RequestCount", 1)
    put_metric("LatencyMs", latency_ms, "Milliseconds")
    if response.status_code >= 400:
        put_metric("ErrorCount", 1)

    logger.info(
        json.dumps({
            "path": request.url.path,
            "method": request.method,
            "status": response.status_code,
            "latency_ms": round(latency_ms, 2),
        })
    )
    return response


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/hello/{name}")
def hello(name: str):
    logger.info(json.dumps({"event": "hello", "name": name}))
    return {"message": f"Hello, {name}!"}


@app.post("/transaction")
async def transaction(request: Request):
    try:
        payload = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="invalid JSON body")

    if not payload.get("amount"):
        raise HTTPException(status_code=400, detail="amount is required")

    logger.info(json.dumps({"event": "transaction", "amount": payload["amount"]}))
    return {"status": "processed", "amount": payload["amount"]}
