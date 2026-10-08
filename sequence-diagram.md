# Invoice Processing Automated — UML Sequence Diagram

**Workflow ID:** `InfDUsLVIxCSqqlg`

Mô tả tương tác giữa các thành phần theo thời gian: Client → n8n Webhook → OpenAI → Validate → Google Sheets → Slack → Approver.

```mermaid
sequenceDiagram
    autonumber
    participant C as Client
    participant W as n8n Webhook
    participant AI as OpenAI gpt-4o-mini
    participant V as Validate (Code)
    participant GS as Google Sheets
    participant SL as Slack
    participant AP as Approver

    C->>W: POST /invoice-incoming {invoiceText, fileName}
    activate W
    W->>AI: extract invoice data (system + user prompt)
    activate AI
    AI-->>W: JSON {vendor, billTo, invoiceNumber, totalAmount, lineItems[]}
    deactivate AI
    W->>V: validate + math check
    activate V
    V-->>W: validated row + mathCheck = OK
    deactivate V
    W->>GS: append row (status = Pending)
    activate GS
    GS-->>W: row appended
    deactivate GS
    W->>SL: notify team (vendor, amount, invoice#)
    activate SL
    SL-->>W: message sent
    deactivate SL

    alt totalAmount > 1000 (high value)
        W->>SL: request approval (includes $execution.resumeUrl)
        activate SL
        SL->>AP: approval request + resume URL
        activate AP
        AP->>W: POST resumeUrl {invoiceNumber, status: "Approved"/"Rejected"}
        deactivate AP
        deactivate SL
        alt status = Approved
            W->>GS: update status = Approved (match Invoice Number)
        else status = Rejected
            W->>GS: update status = Rejected (match Invoice Number)
        end
    else totalAmount <= 1000 (normal)
        W->>GS: auto-approve (match Invoice Number, status = Approved)
    end
    deactivate W
```

## Ký hiệu

| Ký hiệu | Ý nghĩa |
|---|---|
| `->>` (solid arrow) | Call message (đồng bộ) |
| `-->>` (dashed arrow) | Return message (trả về) |
| `activate / deactivate` | Activation bar (lifeline đang xử lý) |
| `alt / else / end` | Combined fragment — lựa chọn |
| `autonumber` | Tự động đánh số thứ tự message |

## Ghi chú

- **Wait for Approval** node sinh webhook URL tại runtime (`{{ $execution.resumeUrl }}`) → Approver POST `{invoiceNumber, status}` vào URL đó. Execution tạm dừng cho đến khi có request.
- Sau khi resume, dữ liệu đầu vào của node tiếp theo = payload approver POST → **Update Invoice Status** dùng `columns.matchingColumns: ["Invoice Number"]` để tìm row và cập nhật Status.
- Nếu AI extraction thất bại hoặc Validate thiếu field bắt buộc → workflow error (có thể route sang error workflow).
- `mathCheck = MISMATCH` khi `|calcTotal − totalAmount| ≥ 0.05` → flag hóa đơn cần review thủ công.
- Có thể thêm combined fragment `opt` (tùy chọn), `loop` (lặp), `par` (đồng thời) nếu cần.
- **Alternative:** thay Request Approval + Wait bằng Slack node operation `sendAndWait` (Send and Wait for Response) — approver bấm button trong Slack, response tự động flow qua. Cần Slack OAuth2 có bật interactivity.
