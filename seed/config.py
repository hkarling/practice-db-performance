import os

DB_CONFIG = {
  "host": os.environ.get("SEED_DB_HOST", "localhost"),
  "port": int(os.environ.get("SEED_DB_PORT", "5432")),
  "dbname": os.environ.get("SEED_DB_NAME", "practice_db_performance"),
  "user": os.environ.get("SEED_DB_USER", "practice"),
  "password": os.environ.get("SEED_DB_PASSWORD", "practice"),
}

# 1 = 풀 스케일, 1000 = 1/1000 축소 (스모크 테스트용)
SCALE_DOWN = int(os.environ.get("SEED_SCALE_DOWN", "1"))

NUM_CATEGORIES = 50
NUM_SELLERS = 50_000 // SCALE_DOWN
NUM_PRODUCTS = 200_000 // SCALE_DOWN
NUM_CUSTOMERS = 1_000_000 // SCALE_DOWN
NUM_ORDERS = 5_000_000 // SCALE_DOWN

ORDER_STATUS_WEIGHTS = {
  "DELIVERED": 0.70,
  "SHIPPED": 0.10,
  "CANCELLED": 0.08,
  "PROCESSING": 0.07,
  "REFUNDED": 0.05,
}

REVIEW_RATE_FOR_DELIVERED = 0.60

OUTPUT_DIR = "output"
