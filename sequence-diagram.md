# Invoice Processing Automated — UML Sequence Diagram

**Workflow ID:** `InfDUsLVIxCSqqlg`

Mô tả tương tác giữa các thành phần theo thời gian: Client → n8n Webhook → Google Gemini → Validate → (Google Sheets | Slack | Router) → Approver.

```mermaid
sequenceDiagram
    autonumber
    participant C as Client
    participant W as n8n Webhook
    participant AI as Google Gemini 3.5-flash-lite
    participant V as Validate (Code)
    participant GS as Google Sheets
    participant SL as Slack
    participant AP as Approver
    participant EH as Error Handler Workflow

    C->>W: POST /invoice-incoming {invoiceText, fileName}
    activate W
    W->>AI: POST :generateContent (system + user prompt)
    activate AI
    AI-->>W: candidates[0].content.parts[0].text = JSON
    deactivate AI
    W->>V: parse + validate + math check
    activate V
    V-->>W: validated row (flat) + mathCheck
    deactivate V

    rect rgb(240, 240, 240)
    Note over W,V: Validate fan-out — n8n chạy tuần tự [1] → [2] → [3]
    W->>GS: [1] append row (status = Pending)
    activate GS
    GS-->>W: Sheets API response
    deactivate GS
    W->>SL: [2] notify team (vendor, amount, invoice#)
    activate SL
    SL-->>W: Slack API response
    deactivate SL
    W->>W: [3] router: totalAmount > 1000 ?
    end

    alt totalAmount > 1000 (high value)
        W->>SL: request approval (includes $execution.resumeUrl)
        activate SL
        SL->>AP: approval request + resume URL
        activate AP
        AP->>W: POST resumeUrl {invoiceNumber, status} (httpMethod: POST)
        deactivate AP
        deactivate SL
        Note over W: execution resume — data nested trong body
        alt $json.body.status = Approved
            W->>GS: update → match columns.matchingColumns ["Invoice Number"] = Approved
        else $json.body.status = Rejected
            W->>GS: update → match Invoice Number = Rejected
        end
    else totalAmount <= 1000 (normal)
        W->>GS: auto-approve (match Invoice Number, status = Approved)
    end
    deactivate W

    opt bất kỳ node nào fail (exception)
        W--)EH: settings.errorWorkflow → Error Trigger
        activate EH
        EH->>SL: notify: workflow, failed node, error, execution URL
        deactivate EH
    end
```

## Ký hiệu

| Ký hiệu | Ý nghĩa |
|---|---|
| `->>` (solid arrow) | Call message (đồng bộ) |
| `-->>` (dashed arrow) | Return message (trả về) |
| `--)` (dashed open) | Asynchronous message (fire-and-forget) |
| `activate / deactivate` | Activation bar (lifeline đang xử lý) |
| `alt / else / end` | Combined fragment — lựa chọn |
| `opt / end` | Combined fragment — tùy chọn |
| `rect rgb(...)` | Vùng tô nền (nhóm message) |
| `autonumber` | Tự động đánh số thứ tự message |

## Ghi chú

- **Validate fan-out:** `Validate & Format` sinh nhiều token ra 3 nhánh ([1] Sheets append, [2] Slack notify, [3] router). Nguyên nhân: node Sheets/Slack trả về **API response** thay thế data chain — nếu nối tiếp tuyến tính, node sau nhận `undefined` → rẽ sai nhánh + message thiếu dữ liệu. n8n thực thi tuần tự theo thứ tự khai báo.
- **Data nesting (webhook):** n8n Webhook node output lồng payload trong `body` → expression dùng `$json.body.invoiceText || $json.invoiceText`.
- **Wait for Approval** (`resume: webhook`, `httpMethod: POST`): execution tạm dừng, `$execution.resumeUrl` sinh tại runtime. Approver POST `{"invoiceNumber": "...", "status": "Approved"}`. Nếu không set `httpMethod: POST` → mặc định GET → resume bị 404 "no waiting webhook with a matching path/method".
- **Sau resume**, dữ liệu đầu vào node tiếp theo cũng nested trong `body` → `Update Invoice Status` dùng `$json.body.invoiceNumber || $json.invoiceNumber`, và `columns.matchingColumns: ["Invoice Number"]` để tìm row.
- **Exception path** (đã implement): `settings.errorWorkflow` → workflow `Invoice Error Handler` (Error Trigger → Slack). Chỉ chạy cho **production executions**; trigger khi bất kỳ node nào fail. Đã verify.
- `mathCheck = MISMATCH` khi `|calcTotal − totalAmount| ≥ 0.05` → không rẽ nhánh, vẫn ghi Sheets kèm flag (cần review thủ công).
- **Alternative:** thay Request Approval + Wait bằng Slack node operation `sendAndWait` (Send and Wait for Response) — approver bấm button trong Slack, response tự động flow qua. Cần Slack OAuth2 có bật interactivity.
