import os

import gen_categories
import gen_customers
import gen_orders
import gen_products
import gen_sellers
from config import OUTPUT_DIR
from load import copy_csv


def path(name: str) -> str:
  return os.path.join(OUTPUT_DIR, name)


def main() -> None:
  print("=== generating CSVs ===")
  gen_categories.generate()
  gen_sellers.generate()
  gen_customers.generate()
  gen_products.generate()
  gen_orders.generate()

  print("=== loading into Postgres ===")
  copy_csv("categories", ["name"], path("categories.csv"))
  copy_csv("sellers", ["name", "city", "state", "zip_code"],
           path("sellers.csv"))
  copy_csv("customers", ["name", "email", "city", "state", "zip_code"],
           path("customers.csv"))
  copy_csv("products", ["category_id", "name", "weight_g"],
           path("products.csv"))
  copy_csv("orders", ["customer_id", "status", "ordered_at"],
           path("orders.csv"))
  copy_csv("order_items",
           ["order_id", "product_id", "seller_id", "price", "freight_value"],
           path("order_items.csv"))
  copy_csv("order_payments",
           ["order_id", "payment_type", "installments", "payment_value",
            "status"], path("order_payments.csv"))
  copy_csv("order_reviews", ["order_id", "rating", "comment"],
           path("order_reviews.csv"))
  copy_csv("delivery",
           ["order_id", "shipped_at", "delivered_at", "estimated_delivery_at"],
           path("delivery.csv"))

  print("done")


if __name__ == "__main__":
  main()
