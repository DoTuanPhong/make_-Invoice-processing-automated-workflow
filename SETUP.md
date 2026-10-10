# Setup Guide — Invoice Processing Automated Workflow

> Hướng dẫn setup **từ đầu** trên n8n self-hosted. Toàn bộ bước dưới đây đã được thực hiện và verify end-to-end ngày 2026-10-10.
>
> **Chi phí: 0 đồng** — cả 3 service đều có free tier (Google Gemini, Google Sheets, Slack).

---

## 0. Kiến trúc tổng quan

```
Client ──POST invoiceText──> n8n Webhook (POST /webhook/invoice-incoming)
                                  │
                                  ▼
                        AI Extract Invoice ──> Google Gemini API (HTTP Request)
                                  │  responseMimeType: application/json
                                  ▼
                        Validate & Format (Code node)
                                  │  check required fields + mathCheck
                    ┌─────────────┼──────────────┐
                    ▼             ▼              ▼
              Log Invoice   Notify Team    High Value?
              (Sheets)      (Slack)         totalAmount > 1000?
              terminal      terminal           ├─ true  → Request Approval → Wait → Update Status
                                                └─ false → Auto-Approve

Exception: bất kỳ node fail ──> Error Trigger workflow ──> Slack
```

**Workflow chính:** `InfDUsLVIxCSqqlg` · **Error workflow:** `QhFlC3iKhUbPOf8R`
**n8n:** http://127.0.0.1:5678

---

## 1. Prerequisites — cài n8n

```powershell
# Node.js 24 LTS (npm 11)
node -v          # v24.19.0
npm -v           # 11.17.0

# Cài n8n global
npm install -g n8n

# Chạy
n8n start        # mặc định http://127.0.0.1:5678

# Kiểm tra
Invoke-WebRequest http://127.0.0.1:5678/healthz    # 200 OK
```

**DB:** SQLite tại `C:\Users\Admin\.n8n\database.sqlite`

> Nếu cần tự động hóa (tạo credentials/workflows bằng script), bật **Public API**: trong n8n UI → Settings → API → Create API Key, copy key `key1` (scopes cần có `workflow:create`, `workflow:activate`, `credential:create`).

---

## 2. Tạo accounts & API keys (đều free)

### 2.1 Google Gemini API key

1. Vào https://aistudio.google.com → đăng nhập Google
2. **Get API key** → Create API key → copy (dạng `AQ.Ab8RN6...` hoặc `AIza...`)
3. Free tier: đủ cho ~hàng trăm hóa đơn/ngày

**Kiểm tra model khả dụng** (quan trọng — model hay bị đổi):
```bash
curl "https://generativelanguage.googleapis.com/v1beta/models?key=YOUR_KEY"
```
Xem dòng `supportedGenerationMethods` có chứa `generateContent`.

> ⚠️ **Gotcha:** model phổ biến (`gemini-2.5-flash`) có thể trả về HTTP 503 *"no longer available to new users"* hoặc *"experiencing high demand"*. Các model thay thế đã thử: `gemini-3.8-flash` (hay 503), `gemini-3.5-flash-lite` (**ổn định, đang dùng**).

### 2.2 Google Cloud Service Account (cho Google Sheets)

1. Vào https://console.cloud.google.com → tạo project (vd `robust-form-511513-i0`)
2. **APIs & Services → Library** → tìm `Google Sheets API` → **ENABLE**
3. **APIs & Services → Credentials → Create Credentials → Service Account**
4. Vào service account vừa tạo → tab **Keys → Add Key → Create new key → JSON**
5. Tải file JSON về. Lấy 2 giá trị:
   - `client_email` (vd `n8n-255@robust-form-511513-i0.iam.gserviceaccount.com`)
   - `private_key` (dạng `-----BEGIN PRIVATE KEY-----\n...`)

> ⚠️ **Gotcha lớn nhất:** nếu chưa Enable Sheets API, mọi call trả `403: Google Sheets API has not been used in project <number>`. Phải enable và **đợi vài phút** propagate (thử ngay sau 30s vẫn sẽ fail).

> ⚠️ Service account **không thể tạo spreadsheet mới** (403 *"The caller does not have permission"* — do org policy). Nên phải **tạo sheet thủ công** rồi share cho service account.

### 2.3 Slack App + Bot Token

1. Vào https://api.slack.com/apps/ (root redirects sang docs.slack.dev, nhưng `/apps/` vẫn dùng được)
2. **Create New App → From scratch** → đặt tên (vd `Invoice Bot`) → chọn workspace
3. **OAuth & Permissions → Bot Token Scopes → Add an OAuth Scope**, thêm:
   - `chat:write` — post message
   - `channels:read` — xem public channels
4. Cuộn lên đầu → **Install to Workspace** → Allow
5. Copy **Bot User OAuth Access Token** (dạng `xoxb-...`)

**Lưu ý về channels:**
- Bot chỉ post được channel mà nó **là member** → phải `/invite @TênBot` trong channel, **hoặc**
- Thêm scope `chat:write.public` + reinstall → bot post được mọi public channel mà không cần invite (cách này đã dùng)

---

## 3. Chuẩn bị Google Sheet

1. Tạo spreadsheet mới tại https://sheets.google.com
2. Hàng 1 nhập **14 cột header**:

```
Vendor	Bill To	Invoice Number	Invoice Date	Due Date	PO Number
Payment Terms	Currency	Subtotal	Tax Rate	Tax Amount	Total Amount
Math Check	Status
```

3. **Share** (góc trên phải) → thêm `client_email` của service account → quyền **Editor**

> ⚠️ **Gotcha:** khi share với service account, Google báo *"there is no Google account associated with this email address, you must check the Notify people box"*. Chỉ cần **tích "Notify people" → Send** — service account không cần đọc email hay accept, quyền có hiệu lực ngay.

> ⚠️ Nếu share thiếu quyền ghi, workflow sẽ đọc được nhưng append/update trả `403`. Phải để **Editor**, không phải Viewer.

4. Lấy **Spreadsheet ID** từ URL:
```
https://docs.google.com/spreadsheets/d/<SPREADSHEET_ID>/edit#gid=0
```

---

## 4. Tạo 3 credentials trong n8n

Vào **n8n → Settings → Credentials → Create Credential**. Lưu ý **type** và **data shape** phải chính xác:

### Credential 1: Gemini API

| Field | Value |
|---|---|
| Name | `Gemini API Key` |
| Type | `Query Auth` (httpQueryAuth) |
| Query Parameter Name | `key` |
| Query Parameter Value | `<API key từ aistudio.google.com>` |

> Dùng Query Auth (không đặt key trực tiếp trong URL) đúng best practice.

### Credential 2: Google Sheets (Service Account)

| Field | Value |
|---|---|
| Name | `Google Sheets Service Account` |
| Type | `Service Account` (googleApi) |
| Service Account Email | `<client_email>` |
| Private Key | `<private_key>` |

### Credential 3: Slack

| Field | Value |
|---|---|
| Name | `Slack API - Invoice Bot` |
| Type | `Slack API` (slackApi) |
| Access Token | `xoxb-...` |

**Ghi lại ID** của 3 credential (dùng cho bước import):
- Gemini: `qPHOt65aWK0DjyLQ`
- Google Sheets: `zPP2IPZNZfgpsMjp`
- Slack: `bAVJK6Js9dbqrFE5`

---

## 5. Import workflow

File: `invoice-processing-workflow.json`

**Cách A — qua UI:** n8n → Import from File → chọn JSON → Open

**Cách B — qua API (đã dùng):**
```python
import json, urllib.request
wf = json.load(open("invoice-processing-workflow.json", encoding="utf-8"))
body = {k: wf[k] for k in ("name","nodes","connections","settings") if k in wf}
req = urllib.request.Request(
    "http://127.0.0.1:5678/api/v1/workflows/InfDUsLVIxCSqqlg",
    data=json.dumps(body).encode(), method="PUT",
    headers={"X-N8N-API-KEY": API_KEY, "Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=30)
```

> ⚠️ PUT chỉ nhận field writable: `name`, `nodes`, `connections`, `settings`, `staticData`, `pinData`, `nodeGroups`. Gửi thêm `id`/`active`/`tags`/`meta` sẽ bị 400. Node-level `settings` cũng bị reject → đặt `retryOnFail`/`maxTries`/`waitBetweenTries` ở **cấp node**, không phải trong `node.settings`.

---

## 6. Cấu hình các node còn lại

Sau import, cần gắn credential và điền config:

### 6.1 Gắn credentials (JSON)

| Node | Credential cần gắn |
|---|---|
| AI Extract Invoice (httpRequest) | `httpQueryAuth` → Gemini API Key |
| Log Invoice / Update Invoice Status / Auto-Approve (googleSheets) | `googleApi` → Google Sheets SA |
| Notify Team / Request Approval (slack) | `slackApi` → Slack API - Invoice Bot |

Ngoài ra node Google Sheets phải có `parameters.authentication = "serviceAccount"`.

### 6.2 Điền Google Sheets (3 node)

```json
"documentId": { "__rl": true, "mode": "id",  "value": "<SPREADSHEET_ID>" },
"sheetName":  { "__rl": true, "mode": "name","value": "<tên tab, vd Sheet1>" }
```

> ⚠️ `sheetName` dùng `mode: "name"` — dùng `mode: "id"` sẽ fail (không resolve được).

### 6.3 Cấu hình Slack

```json
"channelId": { "mode": "name", "value": "#<tên-channel>" }
```

---

## 7. Setup Error Handler (best practice)

1. Tạo workflow mới tên **`Invoice Error Handler`** (ID `QhFlC3iKhUbPOf8R`)
2. Node 1: **Error Trigger** (`n8n-nodes-base.errorTrigger`) — không cần parameter
3. Node 2: **Slack** → operation `post`, `select: channel`, `channelId: {mode: name, value: "#<channel>"}` — gắn credential Slack
4. Nội dung message (expression):
```
={{ '🚨 *Workflow Error*\nWorkflow: ' + $json.workflow.name + ' (ID: ' + $json.workflow.id + ')\nFailed node: ' + ($json.execution.lastNodeExecuted || 'trigger') + '\nMode: ' + $json.execution.mode + '\nError: ' + $json.execution.error.message + '\nExecution: ' + $json.execution.url }}
```
5. **Activate** workflow này
6. Link vào workflow chính qua `settings.errorWorkflow`:
```json
{ "settings": { "errorWorkflow": "QhFlC3iKhUbPOf8R" } }
```

> ⚠️ Không thể activate workflow đang có node thiếu credential (*"Cannot publish workflow: Missing required credential"*). Phải gắn credential trước.
> ⚠️ Error workflow chỉ chạy với **production executions**, không chạy khi manual/test.

---

## 8. Activate + Test

### 8.1 Activate workflow chính

Qua UI: nút **Activate** (góc trên phải). Qua API:
```
POST /api/v1/workflows/InfDUsLVIxCSqqlg/activate
```

Webhook nào chỉ hoạt động khi workflow **active** — trước đó POST sẽ trả 404.

### 8.2 Test happy path (hóa đơn thấp)

```bash
curl -X POST http://127.0.0.1:5678/webhook/invoice-incoming \
  -H "Content-Type: application/json" \
  -d '{"invoiceText":"INVOICE\nVendor: Test Co\nInvoice Number: INV-001\nTotal Amount: 100.00\nSubtotal: 100.00\nTax Amount: 0.00","fileName":"t.pdf"}'
```

Kỳ vọng: execution `success`, Sheets có 1 row (Status=Approved), Slack có message.

### 8.3 Test approval flow (hóa đơn cao > 1000)

1. POST hóa đơn `Total Amount: 6050.00`
2. Slack nhận message approval kèm **resume URL** (dạng `http://127.0.0.1:5678/webhook-waiting/<execId>?signature=...`)
3. Approver POST quyết định:
```bash
curl -X POST "<resumeUrl>" -H "Content-Type: application/json" \
  -d '{"invoiceNumber":"INV-XXX","status":"Approved"}'
```
4. Kỳ vọng: execution `success`, Sheets row → `Approved`/`Rejected`

> Lấy resume URL bằng cách đọc DB nếu cần tự động:
```sql
SELECT data FROM execution_data WHERE executionId = <id>;
-- tìm "webhook-waiting"
```

### 8.4 Test exception path

```bash
curl -X POST http://127.0.0.1:5678/webhook/invoice-incoming \
  -H "Content-Type: application/json" \
  -d '{"invoiceText":"abc xyz","fileName":"bad.pdf"}'   # thiếu field bắt buộc
```

Kỳ vọng: main execution **error** (Validate throw) → error workflow **tự động trigger** → Slack nhận message với workflow name, failed node, error message.

---

## 9. Troubleshooting — mọi lỗi đã gặp

| # | Triệu chứng | Nguyên nhân | Cách sửa |
|---|---|---|---|
| 1 | AI Extract 404/503 | model name không khả dụng / quá tải | check `GET /v1beta/models`, đổi model |
| 2 | AI trả toàn `null` | `{{ $json.X }}` trong `jsonBody` **không được evaluate** | dùng `={{ JSON.stringify({...}) }}` |
| 3 | Slack message toàn `undefined` | Sheets/Slack node trả **API response**, phá data chain | fan-out từ `Validate & Format` ra 3 nhánh |
| 4 | IF luôn rẽ false | operator dùng `larger` (tên hiển thị) — đúng là `gt` | sửa operator + thêm `options.version: 1` |
| 5 | Approval POST 404 | Wait node `httpMethod` mặc định **GET** | set `httpMethod: "POST"` |
| 6 | Update Status không đổi row | sau resume data nested trong `body` | `$json.body.X \|\| $json.X` |
| 7 | Google Sheets 403 | chưa Enable Sheets API | enable + đợi propagate |
| 8 | Google Sheets 403 khi ghi | service account chỉ có quyền Viewer | re-share với **Editor** |
| 9 | Slack `channel_not_found` | channel không tồn tại | tạo channel trước |
| 10 | Slack `not_in_channel` | bot chưa là member | `/invite @bot` hoặc scope `chat:write.public` |
| 11 | Không activate được workflow | node thiếu credential | gắn credential đủ rồi activate |
| 12 | `settings.errorWorkflow` bị reject | error workflow chưa active | activate error workflow trước |
| 13 | API key đột nhiên 401 | nhầm key (copy sai ký tự) | đọc key trực tiếp từ DB: `SELECT apiKey FROM user_api_keys WHERE label='key1'` |

---

## 10. Vận hành hàng ngày

### Gửi hóa đơn
```bash
curl -X POST http://127.0.0.1:5678/webhook/invoice-incoming \
  -H "Content-Type: application/json" \
  -d '{"invoiceText":"<nội dung hóa đơn>","fileName":"<tên file>"}'
```

### Các quy tắc nghiệp vụ
- `totalAmount <= 1000` → **tự động duyệt** (Status = Approved)
- `totalAmount > 1000` → **chờ approval**, giữ `Pending` cho tới khi có quyết định
- `mathCheck = MISMATCH` khi `|calcTotal − totalAmount| >= 0.05` → flag review thủ công
- Hóa đơn thiếu `vendor` / `invoiceNumber` / `totalAmount` → execution lỗi → error workflow báo Slack

### Kiểm tra execution
- UI: http://127.0.0.1:5678 → Executions
- API: `GET /api/v1/executions?workflowId=InfDUsLVIxCSqqlg`
- DB: `SELECT id, status, startedAt FROM execution_entity ORDER BY id DESC`

---

## 11. Tham chiếu nhanh — các lệnh hữu ích

```powershell
# Kiểm tra n8n sống
Invoke-WebRequest http://127.0.0.1:5678/healthz

# Xem API keys đang có (kể cả key hợp lệ)
python -c "import sqlite3;c=sqlite3.connect(r'C:\Users\Admin\.n8n\database.sqlite');print(c.execute(\"SELECT label,scopes FROM user_api_keys\").fetchall())"

# Xem credentials đã tạo
python -c "import sqlite3;c=sqlite3.connect(r'C:\Users\Admin\.n8n\database.sqlite');print([r[0] for r in c.execute(\"SELECT name FROM credentials_entity\")])"

# Xem workflow active chưa
python -c "import sqlite3;c=sqlite3.connect(r'C:\Users\Admin\.n8n\database.sqlite');print(c.execute(\"SELECT id,name,active FROM workflow\").fetchall())"
```

---

## 12. Files trong project

| File | Mô tả |
|---|---|
| `SETUP.md` | File này — hướng dẫn setup từ đầu |
| `README.md` | Tổng quan workflow, API, cấu hình hiện tại |
| `invoice-processing-workflow.json` | n8n workflow JSON (export/import) |
| `activity-diagram.md` | UML Activity Diagram (fan-out, swimlane, exception) |
| `sequence-diagram.md` | UML Sequence Diagram |
| `state-diagram.md` | UML State Machine Diagram |
| `check-n8n-db.py` | Script kiểm tra API keys/settings trong DB |
| `workflow/` | Thiết kế gốc (Make) — tham khảo |
| `mcp/` | Cấu hình Make MCP — tham khảo |
