# Homeserver infra: thiết kế

## Mục đích

Quản lý toàn bộ homeserver và Cloudflare bằng code theo kiểu DevOps: không tạo tay, thêm app mới dễ, và dựng lại được cả dịch vụ lẫn dữ liệu trên một máy Ubuntu trắng.

## Mục tiêu

- Một lệnh trên MacBook để áp dụng toàn bộ cấu hình.
- Thêm một app chỉ cần khai báo trong `apps.yaml` và thêm `apps/<name>/compose.yaml`.
- Backup hằng ngày ra ngoài máy, restore đã được thử thật.
- Secrets không bao giờ nằm dạng rõ trong git.
- Chạy lại lần hai không thay đổi gì (idempotent).

## Không làm

- Kubernetes, Swarm, Prometheus/Grafana, Portainer.
- CI tự deploy vào server.
- Quản lý bằng code: mua domain, Tailscale admin, cấu hình bên trong Beszel (tài khoản, cảnh báo), BIOS.

## Thất bại nếu

- Tiếp quản server làm mất dữ liệu Beszel.
- Một app bị public không cần đăng nhập mà không khai báo rõ.
- Bật firewall làm mất đường SSH.

## Hiện trạng

- Server `homeserver`: Ubuntu 26.04.1, i5-6440HQ, 7 GB RAM, còn khoảng 125 GB. Tailscale IP `100.99.61.56`, LAN `192.168.31.110/24`.
- Đã cài tay: Docker 29.10.1, `daemon.json` (log 10 MB x 3), `net.ipv4.ip_nonlocal_bind=1`, `kiman` thuộc nhóm `docker`.
- `~/apps/beszel` (hub trên `100.99.61.56:8090`, agent qua unix socket) và `~/apps/cloudflared` (tunnel `homeserver` tạo tay, network `tunnel`). File `.env` quyền `600`.
- `thermal-log` (script, service, timer) ghi `/var/log/thermal.csv`.
- SSH chỉ dùng key. User quản trị là `kiman` với sudo `NOPASSWD` (giữ nguyên cho Ansible). `ufw` đang tắt. Tailscale SSH đang bật.
- Domain `kimanlab.online` dùng DNS của Cloudflare.
- MacBook có `tofu`, `sops`, `age`, `gh`, `make`; thiếu `ansible`, `ansible-lint`, `restic`.

## Cách tiếp cận

| Cách | Deploy | Đánh đổi |
|---|---|---|
| A | `make deploy` từ MacBook | Đơn giản, không kiểm tra tự động |
| **B (đã chọn)** | CI kiểm tra PR, `make deploy` từ MacBook | An toàn, GitHub không có quyền vào server hay Cloudflare |
| C | CI tự deploy qua Tailscale | Tiện, nhưng GitHub giữ quyền root và token |

## Cấu trúc

```
homeserver-infra/
├── apps.yaml            # danh sách app và cách expose
├── apps/<name>/compose.yaml
├── tofu/                # tunnel, ingress, DNS, Access, backup bucket
├── ansible/             # inventory, playbooks, roles
├── secrets/             # file mã hoá bằng SOPS
├── .github/workflows/
├── renovate.json
└── Makefile
```

## `apps.yaml`

```yaml
apps:
  - name: beszel
    expose:
      hostname: beszel.kimanlab.online
      service: beszel:8090
      access: private
  - name: dozzle
```

- Không có `expose`: chỉ truy cập qua Tailscale, bind vào Tailscale IP.
- `access`: `private` (Cloudflare Access, chỉ email được phép) hoặc `public`. Mặc định `private`.
- Cả OpenTofu và Ansible đọc từ file này.
- App được expose phải tham gia network `tunnel`.

## OpenTofu

- Quản lý: tunnel, ingress, bản ghi DNS, Access application và policy, R2 bucket cho backup.
- Thứ tự phụ thuộc: Access application được tạo trước ingress và DNS.
- State lưu trên R2, bật state encryption. Bucket chứa state tạo tay một lần.
- Tunnel tạo tay được thay bằng tunnel mới do OpenTofu tạo. Tunnel và hostname cũ xoá sau khi tunnel mới chạy.
- Tunnel token là output nhạy cảm, `Makefile` truyền thẳng sang Ansible, không ghi ra đĩa MacBook.

## Ansible

| Role | Việc |
|---|---|
| `base` | gói cơ bản, `unattended-upgrades`, sysctl, sshd chỉ dùng key |
| `docker` | repo Docker, engine, `daemon.json`, nhóm `docker` |
| `firewall` | `ufw`: chặn vào mặc định, cho `tailscale0`, SSH từ LAN |
| `apps` | chép compose, render `.env`, `docker compose up` theo `apps.yaml` |
| `backup` | `restic`, systemd service và timer |
| `thermal` | script và timer log nhiệt độ hiện có |

- Giữ nguyên đường dẫn `~/apps/<name>` để tiếp quản dữ liệu Beszel.
- `firewall`: hẹn giờ tự tắt `ufw`, mở kết nối SSH mới, thành công mới huỷ hẹn giờ.
- Tailscale cài và đăng nhập tay trên máy mới, là điều kiện trước khi chạy Ansible.

## Secrets

- SOPS với khoá `age`. Khoá riêng nằm ngoài repo và có bản sao trong trình quản lý mật khẩu.
- Gồm: Cloudflare API token, khoá R2, mật khẩu `restic`, Beszel `KEY`/`TOKEN`, URL Healthchecks, email được phép qua Access.
- API token chỉ có quyền DNS của zone, Tunnel, Access và R2.

## Backup và restore

- `restic` lên R2, hằng ngày lúc 03:00. Giữ 7 bản ngày, 4 bản tuần, 6 bản tháng.
- Dữ liệu: thư mục dữ liệu trong `~/apps` và `/var/log/thermal.csv`.
- Để dữ liệu nhất quán, container có dữ liệu được dừng trong lúc backup. App có database sau này phải dump trước.
- Khoá R2 trên server chỉ có quyền với bucket backup. Rủi ro chấp nhận: ai chiếm được server có thể xoá backup.
- `make restore` khôi phục vào thư mục tạm. `make restore APPLY=1 [SNAPSHOT=<id>]` ghi đè dữ liệu thật: hỏi xác nhận, dừng container, restore, khởi động lại. (tôi tự quyết)
- Máy mới: restore chạy trước khi app khởi động lần đầu, timer backup chỉ bật sau khi restore xong hoặc được xác nhận bắt đầu mới. (tôi tự quyết)

## Triển khai trên server thật (tôi tự quyết)

- Trước khi thay đổi: kiểm tra lại cổng đang nghe, volume, container; thấy dịch vụ hay dữ liệu ngoài mục Hiện trạng thì dừng và hỏi. Sao lưu tay `~/apps`.
- Thử toàn bộ Ansible trên VM Ubuntu trắng ở MacBook, không dùng tunnel, state hay repo backup thật.
- Tunnel tạo tay chưa có hostname nào, nên thay tunnel không gây gián đoạn.
- Server là laptop, có sẵn màn hình và bàn phím. Chủ máy chọn làm bước `firewall` và reboot từ xa, chấp nhận khả năng mất kết nối tới khi ra tận máy. Trước đó phải kiểm tra `tailscaled` và `ssh` tự chạy khi khởi động, key Tailscale không sắp hết hạn, Wi-Fi tự kết nối.
- Access chỉ đăng nhập bằng Google (cấu hình tay trên dashboard, OpenTofu chỉ tham chiếu), giới hạn theo email được phép. Beszel qua hostname public chỉ dành cho trình duyệt; agent đi đường nội bộ.

## Giám sát

- Beszel: tài nguyên, nhiệt độ, container. Cảnh báo cấu hình trong giao diện.
- Dozzle: xem log, chỉ qua Tailscale, bật đăng nhập.
- Healthchecks.io: ping mỗi 5 phút để biết máy chết, và ping riêng cho backup thành công hoặc lỗi.

## CI và cập nhật

- GitHub Actions trên PR: `tofu fmt` và `validate` (không backend), `ansible-lint`, `yamllint`, `docker compose config`, `gitleaks`. Không cấp secret nào cho CI.
- Image ghim version cụ thể. Renovate mở PR, không auto-merge.

## Lệnh

`make plan`, `make deploy`, `make check` (Ansible check mode), `make backup`, `make restore`.

## Hoàn thành khi

1. `make deploy` chạy lần hai không có thay đổi.
2. `beszel.kimanlab.online` hiện trang Access trước, dữ liệu Beszel cũ còn nguyên.
3. SSH qua Tailscale và LAN vẫn vào được sau khi bật `ufw`.
4. Reboot server, mọi container và timer tự chạy lại.
5. Restore từ R2 ra thư mục tạm khớp dữ liệu.
6. Tắt backup hoặc server thì Healthchecks báo.
7. CI xanh trên PR.
8. Trên VM trắng, Ansible cộng restore cho ra đủ app và dữ liệu.

## Cần chuẩn bị

Repo GitHub private, R2 (bucket state), API token Cloudflare, tài khoản Healthchecks.io, nơi cất khoá `age` và mật khẩu `restic`.
