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
        W->>SL: request approval
        activate SL
        SL->>AP: approval request
        activate AP
        AP->>W: POST approval webhook {approved: true/false}
        deactivate AP
        deactivate SL
        alt approved
            W->>GS: update status = Approved
        else rejected
            W->>GS: update status = Rejected
        end
    else totalAmount <= 1000 (normal)
        W->>GS: auto-approve (status = Approved)
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

- **Wait for Approval** node sinh webhook URL tại runtime → Approver POST `{approved: bool}` vào URL đó.
- Nếu AI extraction thất bại hoặc Validate thiếu field bắt buộc → workflow error (có thể route sang error workflow).
- `mathCheck = MISMATCH` khi `|calcTotal − totalAmount| ≥ 0.05` → flag hóa đơn cần review thủ công.
- Có thể thêm combined fragment `opt` (tùy chọn), `loop` (lặp), `par` (đồng thời) nếu cần.
