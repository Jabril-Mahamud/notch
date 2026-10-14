from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .database import Base, engine, get_db
from .models import Visit


@asynccontextmanager
async def lifespan(app: FastAPI):
    # ponytail: create_all, not migrations. Add Alembic once the schema changes.
    Base.metadata.create_all(engine)
    yield


# The ingress sends /api to this container without stripping the prefix,
# so every route lives under /api.
app = FastAPI(lifespan=lifespan, docs_url="/api/docs", openapi_url="/api/openapi.json")


@app.get("/api/health")
def health() -> dict:
    return {"ok": True}


@app.post("/api/visits")
def add_visit(db: Session = Depends(get_db)) -> dict:
    db.add(Visit())
    db.commit()
    return {"visits": db.scalar(select(func.count()).select_from(Visit))}
