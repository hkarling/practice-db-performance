from db import get_connection


def copy_csv(table: str, columns: list[str], csv_path: str) -> None:
  column_list = ", ".join(columns)
  with get_connection() as conn:
    with conn.cursor() as cur, open(csv_path, "r", encoding="utf-8") as f:
      cur.copy_expert(
          f"COPY {table} ({column_list}) FROM STDIN WITH (FORMAT csv)", f)
    conn.commit()
  print(f"loaded {csv_path} -> {table}")
