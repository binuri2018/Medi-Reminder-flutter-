from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from api.routes_mode import router as mode_router
from api.routes_reminders import router as reminders_router

app = FastAPI(title="Indoor-Outdoor Reminder Backend", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health_check():
    return {"status": "ok"}


app.include_router(mode_router, prefix="/api")
app.include_router(reminders_router, prefix="/api")
