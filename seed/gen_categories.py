import csv
import os
from pathlib import Path

from config import OUTPUT_DIR

# len()이 config.NUM_CATEGORIES(50)와 일치해야 함
CATEGORY_NAMES = [
  "Electronics", "Home & Kitchen", "Books", "Toys & Games", "Sports & Outdoors",
  "Beauty & Personal Care", "Health & Household", "Clothing", "Shoes",
  "Jewelry", "Automotive", "Office Products", "Pet Supplies",
  "Garden & Outdoor", "Baby Products", "Furniture", "Musical Instruments",
  "Video Games", "Movies & TV", "Grocery", "Tools & Home Improvement",
  "Arts & Crafts", "Computers", "Cell Phones", "Cameras", "Watches", "Luggage",
  "Appliances", "Industrial & Scientific", "Software", "Collectibles",
  "Party Supplies", "Bath", "Bedding", "Lighting", "Rugs",
  "Storage & Organization", "Kitchen & Dining", "Outdoor Recreation", "Fitness",
  "Hunting & Fishing", "Cycling", "Camping & Hiking", "Team Sports", "Golf",
  "Skincare", "Haircare", "Fragrance", "Makeup", "Vitamins & Supplements",
]


def generate() -> None:
  Path(OUTPUT_DIR).mkdir(parents=True, exist_ok=True)
  path = os.path.join(OUTPUT_DIR, "categories.csv")
  with open(path, "w", newline="", encoding="utf-8") as f:
    writer = csv.writer(f)
    for name in CATEGORY_NAMES:
      writer.writerow([name])
  print(f"generated {path} ({len(CATEGORY_NAMES)} rows)")


if __name__ == "__main__":
  generate()
