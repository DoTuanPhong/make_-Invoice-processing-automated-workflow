import sqlite3

conn = sqlite3.connect(r"C:\Users\Admin\.n8n\database.sqlite")
cur = conn.cursor()

# user_api_keys schema
cur.execute("PRAGMA table_info(user_api_keys)")
print("user_api_keys columns:", [(r[1], r[2]) for r in cur.fetchall()])
cur.execute("SELECT * FROM user_api_keys")
rows = cur.fetchall()
print("user_api_keys rows:", len(rows))
for r in rows:
    print("  KEY ROW:", r)

# settings table - all keys
cur.execute("SELECT key FROM settings")
print("SETTINGS KEYS:", [r[0] for r in cur.fetchall()])

# invalid_auth_token (may hold MCP tokens)
try:
    cur.execute("PRAGMA table_info(invalid_auth_token)")
    print("invalid_auth_token columns:", [(r[1], r[2]) for r in cur.fetchall()])
    cur.execute("SELECT COUNT(*) FROM invalid_auth_token")
    print("invalid_auth_token count:", cur.fetchone()[0])
except Exception as e:
    print("err:", e)

conn.close()
