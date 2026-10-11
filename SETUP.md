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
2. Hàng 1 nhập **15 cột header** (cột cuối `Dedup Key` bắt buộc):

```
Vendor	Bill To	Invoice Number	Invoice Date	Due Date	PO Number
Payment Terms	Currency	Subtotal	Tax Rate	Tax Amount	Total Amount
Math Check	Status	Dedup Key
```

> `Dedup Key` là khoá chống trùng = `VENDOR|INVOICE_NUMBER` (viết hoa). Số hóa đơn chỉ unique **theo từng vendor**, nên không thể match một mỉnh `Invoice Number` — nếu không có cột này, `appendOrUpdate` sẽ fail.

3. **Share** (góc trên phải) → thêm `client_email` của service account → quyền **Editor**

> ⚠️ **Gotcha:** khi share với service account, Google báo *"there is no Google account associated with this email address, you must check the Notify people box"*. Chỉ cần **tích "Notify people" → Send** — service account không cần đọc email hay accept, quyền có hiệu lực ngay.

> ⚠️ Nếu share thiếu quyền ghi, workflow sẽ đọc được nhưng append/update trả `403`. Phải để **Editor**, không phải Viewer.

4. Lấy **Spreadsheet ID** từ URL:
```
https://docs.google.com/spreadsheets/d/<SPREADSHEET_ID>/edit#gid=0
```

---

### 3.1 Tab `Exceptions` (DLQ của error handler)

Tạo thêm 1 tab tên **`Exceptions`**, 13 cột:

```
Exception ID | Timestamp | Execution ID | Failed Node | Category
Severity | Error Message | Execution URL | Retry Of | Mode
Status | Resolution | Notes
```

Error workflow ghi mỗi lỗi vào đây (`appendOrUpdate`, khoá `Exception ID`) để xử lý sau.

---

## 4. Tạo 4 credentials trong n8n

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
| Invoice Webhook (webhook) | `httpHeaderAuth` → Invoice Webhook Key |
| AI Extract Invoice (httpRequest) | `httpQueryAuth` → Gemini API Key |
| Log Invoice / Update Invoice Status / Auto-Approve (googleSheets) | `googleApi` → Google Sheets SA |
| Notify Team / Request Approval / Notify Finance Errors (slack) | `slackApi` → Slack API - Invoice Bot |

Ngoài ra node Google Sheets phải có `parameters.authentication = "serviceAccount"`, node webhook phải có `parameters.authentication = "headerAuth"`.

### 6.2 Điền Google Sheets (3 node)

`Log Invoice` dùng operation **`appendOrUpdate`** (upsert) với `matchingColumns: ["Dedup Key"]` — gửi lại cùng hóa đơn sẽ **cập nhật dòng cũ** thay vì tạo dòng trùng.

```json
"documentId": { "__rl": true, "mode": "id",  "value": "<SPREADSHEET_ID>" },
"sheetName":  { "__rl": true, "mode": "name","value": "<tên tab, vd Sheet1>" }
```

> ⚠️ `sheetName` dùng `mode: "name"` — dùng `mode: "id"` sẽ fail (không resolve được).

### 6.3 Bật xác thực cho Webhook (bắt buộc)

Mặc định webhook **không có auth** — ai reach được port 5678 là post được hóa đơn giả. Đã bật header auth:

| Field | Giá trị |
|---|---|
| Name | `Invoice Webhook Key` |
| Type | `Header Auth` (httpHeaderAuth) |
| Header Name | `x-invoice-key` |
| Header Value | `<chuỗi ngẫu nhiên> `x-inv-<40 ký tự>` |

Giá trị chỉ hiển thị trong n8n UI (Credentials → Invoice Webhook Key → Header Value) — **không ghi vào repo**.

Node `Invoice Webhook` được set `authentication: "headerAuth"` + gắn credential trên. Request thiếu header sẽ trả **403**.

### 6.4 Cấu hình Slack

```json
"channelId": { "mode": "name", "value": "#<tên-channel>" }
```

---

## 7. Setup Error Handler (best practice)

1. Tạo workflow mới tên **`Invoice Error Handler v2`** (ID `U84rJVpHTLNOA68Q`)
   — import sẵn từ `error-handler-workflow.json`
2. Chuỗi 4 node:
   | # | Node | Loại | Ghi chú |
   |---|---|---|---|
   | 1 | `Error Trigger` | `n8n-nodes-base.errorTrigger` | Không cần parameter |
   | 2 | `Classify & Format` | `code` (mode `runOnceForAllItems`) | Phân loại lỗi + dựng DLQ row + format Slack text |
   | 3 | `Write DLQ Record` | `googleSheets` | `appendOrUpdate` trên tab **`Exceptions`**, `matchingColumns: ["Exception ID"]` |
   | 4 | `Notify Team` | `slack` | `text = "={{ $('Classify & Format').item.json.slackText }}"` |
3. **Activate** rồi link vào workflow chính qua `settings.errorWorkflow`

**Bảng phân loại** (trong node Code):

| Nhóm lỗi | Severity | Route |
|---|---|---|
| `data/validation` — thiếu field, sai số, sai currency, AI trả không phải JSON | warning | AP Clerk |
| `infra/permission` — thiếu credential, sai private key, 403 | critical | IT |
| `Google API` — Sheets API chưa bật, hết quota, rate limit | critical | IT |
| `Slack/integration` — `channel_not_found`, `not_in_channel`, `invalid_auth` | critical | IT |
| `transient (API)` — 429/503/timeout/fetch failed (đã hết retry ×3) | warning | AP Clerk |
| `unknown` — không khớp pattern nào | critical | IT |

> ⚠️ **`Write DLQ Record` phải để `typeVersion: 4`** — bản **4.5** đòi thêm `columns.schema`
> (`getNodeParameter('columns.schema')` không có default → throw *"Could not get parameter"*).
> Các node Sheets của workflow chính đều đang ở version 4.
>
> ⚠️ `Notify Team` **phải** tham chiếu `$('Classify & Format')` chứ không phải `$json` —
> vì `Write DLQ Record` trả về Sheets API response, làm mất data chain.
>
> ⚠️ Không thể activate workflow đang thiếu credential (*"Cannot publish workflow: Missing required credential"*).
>
> ⚠️ Error workflow chỉ chạy với **production executions**, không chạy khi manual/test.

**Nếu link bị từ chối** `The selected error workflow has no published version` — đợi ~10s rồi
thử lại (độ trễ publish, không phải lỗi cấu hình).

**V1 cũ** (chỉ `Error Trigger → Slack`) đã được **archive** + lưu JSON tại
`error-handler-v1-archived.json` để hoàn tác. Muốn quay lại: bỏ archive, activate,
đổi `settings.errorWorkflow` về `QhFlC3iKhUbPOf8R`.

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
  -H "Content-Type: application/json" -H "x-invoice-key: <KEY>" \
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
  -H "Content-Type: application/json" -H "x-invoice-key: <KEY>" \
  -d '{"invoiceText":"abc xyz","fileName":"bad.pdf"}'   # thieu field bat buoc
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
| 12 | `settings.errorWorkflow` bị reject `no published version` | độ trễ publish, **không phải** lỗi config | đợi ~10s rồi retry |
| 13 | DLQ node lỗi `columns.schema is required` / `Could not get parameter columns.schema` | `typeVersion: 4.5` của node Sheets đòi thêm `columns.schema` (bản 4 thì không) | hạ `typeVersion` xuống **4** — bằng workflow chính |
| 14 | Slack lỗi `no_text` trong error handler | `Write DLQ Record` trả Sheets API response → `$json.slackText` undefined | đổi thành `$('Classify & Format').item.json.slackText` |
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

## 11. Bảo mật, PII & khả năng chịu tải

### 11.1 PII chảy ra bên thứ 3 (đã biết, chưa xử lý)

Nội dung hóa đơn — **tên vendor, tên khách hàng, PO, số tiền** — được gửi lên
**Google Gemini API**. Ở free tier, điều khoản của Google cho phép dùng prompt
để cải thiện sản phẩm. Trước khi dùng production với dữ liệu nhạy cảm cần:

- Chuyển sang tier trả phí / enterprise agreement, **hoặc**
- Thay Gemini bằng model local (Ollama / vLLM), **hoặc**
- Che (mask) thông tin nhạy cảm trước khi gửi cho AI

Hiện **chưa có** bước mask nào trong workflow.

### 11.2 Khả năng chịu tải

| Thành phần | Giới hạn | Ghi chú |
|---|---|---|
| Gemini free tier | ~15 request/phút | đủ ~900–1.500 hóa đơn/ngày, **verify lại limit thực tế** cho model đang dùng |
| Google Sheets API | ~300 write/phút, ~60 read/phút theo project | mỗi hóa đơn ~1 lệnh ghi (upsert) |
| Slack | ~1 message/giây/channel | không phải bottleneck |

**Bottleneck thật là con người:** mỗi hóa đơn >1000 hoặc lệch số học để lại 1
execution `waiting` cho tới khi có người bấm duyệt (tối đa 7 ngày).
300 hóa đơn/ngày = 300 execution chờ — đó mới là chỗ đứt gãy, không phải API.

n8n chạy **mặc định** nhiều execution song song. Kiểm soát burst bằng env var
(không phải workflow settings — n8n không có `concurrency` cấp workflow):

```powershell
# giới hạn số execution production chạy đồng thời
$env:N8N_CONCURRENCY_PRODUCTION = "5"
n8n start
```

Node Google Sheets / Slack đã có `retryOnFail` (3 lần, chờ 2s) để chịu được
429 tạm thời khi burst.

### 11.3 API key n8n hết hạn

Key dùng cho automation (`key1`) có `exp` nhúng trong JWT:

```powershell
python -c "import sqlite3,json,base64;c=sqlite3.connect(r'C:\Users\Admin\.n8n\database.sqlite');k=c.execute(\"SELECT apiKey FROM user_api_keys WHERE label='key1'\").fetchone()[0];p=k.split('.')[1];p+='='*(-len(p)%4);print(json.loads(base64.urlsafe_b64decode(p))['exp'])"
```
→ Đổi sang người đọc được và **đặt lịch rotate trước 30 ngày**. Key hết hạn
sẽ khiến mọi script/API call **fail im lặng**.

### 11.4 Audit trail

Payload approval nên có `approvedBy` (và `comment`) — hiện chỉ là **khuyến
nghị trong message Slack**, workflow **không validate** và **không lưu** vào
sheet (không có cột cho nó). Nếu cần bằng chứng phân quyền, thêm 2 cột
`Approved By` / `Approved At` và map vào `Update Invoice Status`.

---

## 13. Files trong project

| File | Mô tả |
|---|---|
| `BUSINESS-SPEC.md` | Đặc tả nghiệp vụ đầy đủ — tính năng, quy tắc, lộ trình đã và sắp làm (xem để biết hướng đi) |
| `SETUP.md` | File này — hướng dẫn setup từ đầy đầy |
| `README.md` | Tổng quan workflow, API, cấu hình hiện tại |
| `invoice-processing-workflow.json` | n8n workflow JSON (export/import) |
| `activity-diagram.md` | UML Activity Diagram (fan-out, swimlane, exception) |
| `sequence-diagram.md` | UML Sequence Diagram |
| `state-diagram.md` | UML State Machine Diagram |
| `check-n8n-db.py` | Script kiểm tra API keys/settings trong DB |
| `workflow/`, `mcp/` | **ĐÃ BỎ** — thiết kế Make.com gốc, xem banner ở đầu `workflow/01-workflow-design.md` |
| `mcp/` | Cấu hình Make MCP — tham khảo |
