import csv
import os
import random
from faker import Faker
from pathlib import Path

from config import NUM_CATEGORIES, NUM_PRODUCTS, OUTPUT_DIR

fake = Faker("pt_BR")
Faker.seed(44)
random.seed(44)


def generate() -> None:
  Path(OUTPUT_DIR).mkdir(parents=True, exist_ok=True)
  path = os.path.join(OUTPUT_DIR, "products.csv")
  with open(path, "w", newline="", encoding="utf-8") as f:
    writer = csv.writer(f)
    for _ in range(NUM_PRODUCTS):
      category_id = random.randint(1, NUM_CATEGORIES)
      writer.writerow(
          [category_id, fake.catch_phrase(), random.randint(50, 5000)])
  print(f"generated {path} ({NUM_PRODUCTS} rows)")


if __name__ == "__main__":
  generate()
