from services.dispatcher_service import DispatcherService
from services.fcm_service import FcmService
from services.mode_service import ModeService
from storage.state_store import StateStore

store = StateStore()
mode_service = ModeService(store)
fcm_service = FcmService()
dispatcher_service = DispatcherService(mode_service, store, fcm_service)
