# Bàn giao: homeserver-infra (27/11/2026)

Việc còn lại: **Task 8, chuyển server thật sang quản lý bằng code**.

## Đọc trước

1. Repo: `/Users/anvu-neli/homeserver-infra`
2. Thiết kế: `docs/superpowers/specs/2026-11-27-homeserver-infra-design.md`
3. Kế hoạch: `docs/superpowers/plans/2026-11-27-homeserver-infra.md`
4. Sổ tiến độ (mọi `Ruling:` và lỗi để lại): `.superpowers/sdd/2026-11-27-homeserver-infra/progress.md` (git bỏ qua, đừng xoá)

## Quy tắc làm việc

- Trả lời bằng tiếng Việt; code, commit, PR bằng tiếng Anh.
- Không commit, push, tạo PR cho tới khi tôi nói "tạo pull" hoặc `/commit`. Không ghi công Claude trong commit và PR.
- Mỗi bước thay đổi server hoặc Cloudflare phải hỏi trước. Phê duyệt ở phiên trước không áp dụng cho bước mới.
- Không in secret ra màn hình, không yêu cầu tôi dán secret vào chat.

## Môi trường

| Thứ | Giá trị |
|---|---|
| Server | `ssh kiman@100.99.61.56` (Tailscale), LAN `192.168.31.110/24`, Ubuntu 26.04, `sudo` không mật khẩu |
| Domain | `kimanlab.online` (Cloudflare) |
| Secrets | `secrets/prod.sops.yaml`, khoá `~/.config/sops/age/keys.txt` (`make secrets` để sửa) |
| Terraform state | R2 bucket `homeserver-tfstate` |
| Backup | R2 bucket `homeserver-backup` |
| Tunnel mới | `homeserver-iac` (đã tạo, chưa có kết nối) |
| Tunnel cũ | `homeserver` (đang chạy trên server, chưa có hostname) |

## Đã xong

- Task 1–7: secrets, `apps.yaml`, compose, validator, OpenTofu, Ansible, firewall, backup/restore, CI, Renovate.
- OpenTofu **đã apply**: DNS và Access cho `beszel.kimanlab.online` (đăng nhập chỉ Google), tunnel, bucket backup. `plan` sau apply không còn thay đổi.
- 16 secret đã điền.
- Review độc lập: 4 lỗi quan trọng đã sửa. Lỗi nhỏ để lại nằm trong sổ tiến độ (`Final: minor`).
- Kiểm tra gần nhất đạt: pytest 28, `tofu test` 12, `make lint`, test trên máy ảo, diễn tập tiếp quản.
- Repo private `vukiman1/homeserver-infra`, PR #1 (`feat/infra-bootstrap` → `main`) đang mở, chưa merge.
- CI **chưa chạy được**: GitHub từ chối khởi động job do lỗi thanh toán hoặc spending limit của tài khoản. Sửa ở Settings → Billing & plans rồi chạy lại job.
- Repo được cấu hình cục bộ để commit và push bằng tài khoản `vukiman1` (email noreply). Lệnh `gh` cần `GH_TOKEN=$(gh auth token --user vukiman1)`.
- Sổ tiến độ `.superpowers/` chỉ có trên MacBook này, không nằm trong git.

## Server hiện tại

- Cài tay: Docker 29, Beszel và `cloudflared` trong `~/apps`, timer `thermal-log`. Chưa có Dozzle, backup, heartbeat.
- `ufw` đang tắt.
- Giới hạn sạc pin 50–80% đã đặt trên máy (không do code quản lý).
- `beszel.kimanlab.online` báo lỗi 1033 là **đúng dự kiến** cho tới khi deploy.

## Task 8

Tôi đã chọn làm firewall và reboot **từ xa**, chấp nhận mất kết nối thì chờ ra tận máy.

Trước khi bắt đầu: Tailscale trên MacBook đang bật; nhắc tôi **Disable key expiry** cho `homeserver` trong trang admin Tailscale.

| # | Việc | Lệnh | Điều kiện đạt |
|---|---|---|---|
| 1 | Kiểm tra hiện trạng (chỉ đọc) | xem Step 1 trong kế hoạch | Khớp kế hoạch, khác thì dừng và hỏi |
| 2 | Dừng Beszel, nén `~/apps` thành `~/apps-pre-iac.tar.gz` (quyền `600`), bật lại | SSH | File nén đọc được |
| 3 | Xem trước rồi deploy, chưa bật firewall | `make check`, `make deploy` | Dữ liệu Beszel cũ còn; domain hỏi Google rồi vào được |
| 4 | Kiểm tra Dozzle (user `admin`) | `http://100.99.61.56:8080` | Chỉ vào được qua Tailscale |
| 5 | Backup và restore thử | `make backup-init`, `make backup`, `make restore` | File khôi phục khớp |
| 6 | Bật firewall | `make deploy ARGS="-e firewall_confirmed=true"` | SSH mới qua Tailscale vào được; `ufw status` có rule LAN |
| 7 | Kiểm tra `tailscaled`, `ssh` tự chạy khi boot và Wi-Fi tự kết nối, rồi reboot | SSH | Container và timer tự chạy; `make deploy` lần hai `changed=0` |
| 8 | Thử cảnh báo Healthchecks bằng cách tạm dừng heartbeat | SSH | Có thông báo, rồi bật lại |
| 9 | Dọn dẹp | Dashboard | Tôi xoá tunnel cũ `homeserver`; xoá file nén khi tôi đồng ý |

## Cẩn thận

- **Không** dùng `restore_first=true` trên server này.
- `make restore APPLY=1` ghi đè dữ liệu thật.
- `make check` chỉ cho thấy thay đổi file, không báo trước container bị tạo lại.
- Route của tunnel không xoá được bằng OpenTofu.
- Firewall tự tắt sau 5 phút nếu kết nối thử thất bại. Rule SSH từ LAN chỉ thử thật được khi ở nhà.
- Ba máy ảo `homeserver-test`, `homeserver-fresh`, `homeserver-adopt` đang tắt. Xoá khi tôi đồng ý: `multipass delete --purge <tên>`.

## Sau Task 8

- Cấu hình cảnh báo trong Beszel (Slack hoặc Telegram).
- Thêm app mới: tạo `apps/<name>/compose.yaml` (ghim phiên bản, network `tunnel` external), khai báo trong `apps.yaml`, rồi `make test`, `make plan`, `make tofu-apply`, `make deploy`.
- Image private từ GHCR: chưa có phần đăng nhập registry trong code.
- Merge PR #1 sau khi CI xanh và Task 8 đạt (tôi tự quyết định lúc merge).
