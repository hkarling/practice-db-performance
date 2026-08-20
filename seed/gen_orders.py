import csv
import os
import random
from datetime import datetime, timedelta, timezone
from faker import Faker
from pathlib import Path

from config import (
  NUM_CUSTOMERS,
  NUM_ORDERS,
  NUM_PRODUCTS,
  NUM_SELLERS,
  ORDER_STATUS_WEIGHTS,
  OUTPUT_DIR,
  REVIEW_RATE_FOR_DELIVERED,
)

fake = Faker("pt_BR")
Faker.seed(45)
random.seed(45)

ORDER_DATE_START = datetime(2024, 1, 1, tzinfo=timezone.utc)
ORDER_DATE_END = datetime(2026, 1, 1, tzinfo=timezone.utc)
ORDER_DATE_RANGE_SECONDS = int(
    (ORDER_DATE_END - ORDER_DATE_START).total_seconds())

PAYMENT_TYPES = ["CREDIT_CARD", "BOLETO", "VOUCHER", "DEBIT_CARD"]
PAYMENT_TYPE_WEIGHTS = [60, 20, 10, 10]

ITEM_COUNT_CHOICES = [1, 2, 3, 4, 5]
ITEM_COUNT_WEIGHTS = [15, 20, 30, 20, 15]

INSTALLMENT_CHOICES = [1, 2, 3, 6, 10, 12]
INSTALLMENT_WEIGHTS = [40, 15, 15, 15, 10, 5]

RATING_CHOICES = [1, 2, 3, 4, 5]
RATING_WEIGHTS = [5, 5, 15, 35, 40]

STATUS_NAMES = list(ORDER_STATUS_WEIGHTS.keys())
STATUS_WEIGHTS = list(ORDER_STATUS_WEIGHTS.values())


def random_ordered_at() -> datetime:
  offset = random.randint(0, ORDER_DATE_RANGE_SECONDS)
  return ORDER_DATE_START + timedelta(seconds=offset)


def generate() -> None:
  Path(OUTPUT_DIR).mkdir(parents=True, exist_ok=True)

  orders_f = open(os.path.join(OUTPUT_DIR, "orders.csv"), "w", newline="",
                  encoding="utf-8")
  items_f = open(os.path.join(OUTPUT_DIR, "order_items.csv"), "w", newline="",
                 encoding="utf-8")
  payments_f = open(os.path.join(OUTPUT_DIR, "order_payments.csv"), "w",
                    newline="", encoding="utf-8")
  reviews_f = open(os.path.join(OUTPUT_DIR, "order_reviews.csv"), "w",
                   newline="", encoding="utf-8")
  delivery_f = open(os.path.join(OUTPUT_DIR, "delivery.csv"), "w", newline="",
                    encoding="utf-8")

  orders_w = csv.writer(orders_f)
  items_w = csv.writer(items_f)
  payments_w = csv.writer(payments_f)
  reviews_w = csv.writer(reviews_f)
  delivery_w = csv.writer(delivery_f)

  try:
    for order_id in range(1, NUM_ORDERS + 1):
      customer_id = random.randint(1, NUM_CUSTOMERS)
      status = random.choices(STATUS_NAMES, weights=STATUS_WEIGHTS, k=1)[0]
      ordered_at = random_ordered_at()
      estimated_delivery_at = ordered_at + timedelta(days=random.randint(7, 15))

      orders_w.writerow([customer_id, status, ordered_at.isoformat()])

      item_count = \
        random.choices(ITEM_COUNT_CHOICES, weights=ITEM_COUNT_WEIGHTS, k=1)[0]
      order_total = 0.0
      for _ in range(item_count):
        product_id = random.randint(1, NUM_PRODUCTS)
        seller_id = random.randint(1, NUM_SELLERS)
        price = round(random.uniform(10, 500), 2)
        freight_value = round(random.uniform(5, 50), 2)
        order_total += price + freight_value
        items_w.writerow(
            [order_id, product_id, seller_id, price, freight_value])

      payment_status = "REFUNDED" if status in ("CANCELLED",
                                                "REFUNDED") else "PAID"
      payment_type = \
        random.choices(PAYMENT_TYPES, weights=PAYMENT_TYPE_WEIGHTS, k=1)[0]
      installments = \
        random.choices(INSTALLMENT_CHOICES, weights=INSTALLMENT_WEIGHTS, k=1)[0]
      payments_w.writerow(
          [order_id, payment_type, installments, round(order_total, 2),
           payment_status])

      if status in ("SHIPPED", "DELIVERED"):
        shipped_at = ordered_at + timedelta(days=random.randint(1, 3),
                                            hours=random.randint(0, 23))
        delivered_at = None
        if status == "DELIVERED":
          delivered_at = shipped_at + timedelta(days=random.randint(2, 10))
        delivery_w.writerow([
          order_id,
          shipped_at.isoformat(),
          delivered_at.isoformat() if delivered_at else None,
          estimated_delivery_at.isoformat(),
        ])

      if status == "DELIVERED" and random.random() < REVIEW_RATE_FOR_DELIVERED:
        rating = random.choices(RATING_CHOICES, weights=RATING_WEIGHTS, k=1)[0]
        comment = fake.sentence() if random.random() < 0.7 else None
        reviews_w.writerow([order_id, rating, comment])

      if order_id % 500_000 == 0:
        print(f"...{order_id}/{NUM_ORDERS} orders generated")
  finally:
    orders_f.close()
    items_f.close()
    payments_f.close()
    reviews_f.close()
    delivery_f.close()

  print("order-related CSV generation done")


if __name__ == "__main__":
  generate()
