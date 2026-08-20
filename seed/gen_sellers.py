import csv
import os
from faker import Faker
from pathlib import Path

from config import NUM_SELLERS, OUTPUT_DIR

fake = Faker("pt_BR")
Faker.seed(43)


def generate() -> None:
  Path(OUTPUT_DIR).mkdir(parents=True, exist_ok=True)
  path = os.path.join(OUTPUT_DIR, "sellers.csv")
  with open(path, "w", newline="", encoding="utf-8") as f:
    writer = csv.writer(f)
    for _ in range(NUM_SELLERS):
      writer.writerow(
          [fake.company(), fake.city(), fake.estado_sigla(), fake.postcode()])
  print(f"generated {path} ({NUM_SELLERS} rows)")


if __name__ == "__main__":
  generate()
