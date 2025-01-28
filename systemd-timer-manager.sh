#!/bin/bash

CONFIG_DIR="$HOME/.timers"
mkdir -p "$CONFIG_DIR"

# Hiển thị menu
function show_menu() {
  echo "=================="
  echo "QUẢN LÝ SYSTEMD TIMER"
  echo "=================="
  echo "1. Tạo timer mới"
  echo "2. Quản lý timer hiện có"
  echo "3. Thoát"
  echo "=================="
}

# Kiểm tra URL hợp lệ
function is_valid_url() {
  if [[ "$1" =~ ^https?://[a-zA-Z0-9.-]+(/.*)?$ ]]; then
    return 0
  else
    return 1
  fi
}

# Kiểm tra script hợp lệ
function is_valid_script() {
  if [[ -f "$1" && -x "$1" ]]; then
    return 0
  else
    return 1
  fi
}

# Kiểm tra trạng thái timer và màu sắc
function check_timer_status() {
  local timer_name="$1"
  systemctl is-active --quiet "$timer_name.timer"
  if [[ $? -eq 0 ]]; then
    status="\033[32mĐang hoạt động\033[0m" # Màu xanh cho hoạt động
  else
    systemctl is-enabled --quiet "$timer_name.timer"
    if [[ $? -eq 0 ]]; then
      status="\033[33mĐã dừng\033[0m" # Màu vàng cho trạng thái enabled nhưng không active
    else
      status="\033[31mĐã tắt\033[0m" # Màu đỏ cho trạng thái disabled
    fi
  fi

  # Lấy thông tin về loại thực thi (bash hoặc curl)
  if [[ -f "/etc/systemd/system/$timer_name.service" ]]; then
    if grep -q "ExecStart=/usr/bin/curl" "/etc/systemd/system/$timer_name.service"; then
      exec_type="curl"
    elif grep -q "ExecStart=/bin/bash" "/etc/systemd/system/$timer_name.service"; then
      exec_type="bash"
    else
      exec_type="Unknown"
    fi
  else
    exec_type="Unknown"
  fi

  echo -e "$status $exec_type"
}

# Lấy thời gian chạy từ file timer
function get_timer_interval() {
  local timer_name="$1"
  grep -Po 'OnUnitActiveSec=\K.*' "/etc/systemd/system/$timer_name.timer"
}

# Tạo timer mới
function create_timer() {
  while true; do
    read -p "Nhập tên timer (chỉ chữ và số, không chứa dấu cách hoặc ký tự đặc biệt): " TIMER_NAME
    if [[ "$TIMER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      # Kiểm tra xem timer đã tồn tại chưa
      if [[ -f "/etc/systemd/system/$TIMER_NAME.timer" || -f "/etc/systemd/system/$TIMER_NAME.service" ]]; then
        echo "Lỗi: Timer '$TIMER_NAME' đã tồn tại! Vui lòng chọn tên khác."
        continue
      fi
      break
    else
      echo "Tên không hợp lệ! Vui lòng nhập lại tên hợp lệ."
    fi
  done

  while true; do
    read -p "Nhập URL hoặc đường dẫn script cần chạy (hoặc 'back' để quay lại): " TARGET
    if [[ "$TARGET" == "back" ]]; then
      return
    fi

    if is_valid_url "$TARGET"; then
      TYPE="curl"
      EXEC="/usr/bin/curl -s -o /dev/null \"$TARGET\""
      break
    elif is_valid_script "$TARGET"; then
      TYPE="bash"
      EXEC="/bin/bash \"$TARGET\""
      chmod +x "$TARGET"  # Cấp quyền thực thi nếu chưa có
      break
    else
      echo "Lỗi: URL không hợp lệ hoặc script không tồn tại hoặc thiếu quyền thực thi!"
      echo "Vui lòng kiểm tra và thử lại."
    fi
  done

  while true; do
    read -p "Nhập khoảng thời gian chạy (ví dụ: 1s, 10s, 1m) (hoặc 'back' để quay lại): " INTERVAL
    if [[ "$INTERVAL" == "back" ]]; then
      return
    fi
    if [[ "$INTERVAL" =~ ^[0-9]+[smh]$ ]]; then
      break
    else
      echo "Lỗi: Thời gian không hợp lệ! Vui lòng nhập lại (ví dụ: 1s, 10m)."
    fi
  done

  SERVICE_FILE="$CONFIG_DIR/$TIMER_NAME.service"
  TIMER_FILE="$CONFIG_DIR/$TIMER_NAME.timer"

  # Tạo file service
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Run $TYPE for $TARGET

[Service]
Type=oneshot
ExecStart=$EXEC
EOF

  # Tạo file timer
  cat >"$TIMER_FILE" <<EOF
[Unit]
Description=Timer for $TARGET

[Timer]
OnUnitActiveSec=$INTERVAL
AccuracySec=1ms
Unit=$TIMER_NAME.service

[Install]
WantedBy=timers.target
EOF

  # Di chuyển file tới systemd và kích hoạt
  if ! sudo mv "$SERVICE_FILE" /etc/systemd/system/; then
    echo "Lỗi: Không thể di chuyển file service. Kiểm tra quyền sudo hoặc đường dẫn."
    return 1
  fi

  if ! sudo mv "$TIMER_FILE" /etc/systemd/system/; then
    echo "Lỗi: Không thể di chuyển file timer. Kiểm tra quyền sudo hoặc đường dẫn."
    # Nếu không di chuyển được file timer, xóa file service đã di chuyển
    sudo rm -f "/etc/systemd/system/$TIMER_NAME.service"
    return 1
  fi

  # Kiểm tra quyền thực thi
  sudo chmod 644 /etc/systemd/system/$TIMER_NAME.service
  sudo chmod 644 /etc/systemd/system/$TIMER_NAME.timer

  if ! sudo systemctl daemon-reload; then
    echo "Lỗi: Không thể tải lại daemon. Kiểm tra lại cấu hình."
    # Nếu không tải lại daemon được, xóa các file đã tạo
    sudo rm -f "/etc/systemd/system/$TIMER_NAME.service" "/etc/systemd/system/$TIMER_NAME.timer"
    return 1
  fi

  if ! sudo systemctl enable --now "$TIMER_NAME.timer"; then
    echo "Lỗi: Không thể kích hoạt timer: $TIMER_NAME"
    # Nếu không kích hoạt được, xóa các file đã tạo
    sudo rm -f "/etc/systemd/system/$TIMER_NAME.service" "/etc/systemd/system/$TIMER_NAME.timer"
    sudo systemctl daemon-reload
    return 1
  fi

  # Đảm bảo rằng service được bắt đầu
  sudo systemctl start "$TIMER_NAME.service"

  # Kiểm tra trạng thái của timer và service
  if systemctl is-active --quiet "$TIMER_NAME.timer"; then
    echo "Timer $TIMER_NAME đã được tạo và kích hoạt thành công."
  else
    echo "Lỗi: Timer $TIMER_NAME đã được tạo nhưng không kích hoạt được."
    # Nếu không kích hoạt được, xóa các file đã tạo
    sudo rm -f "/etc/systemd/system/$TIMER_NAME.service" "/etc/systemd/system/$TIMER_NAME.timer"
    sudo systemctl daemon-reload
    return 1
  fi
}

# Tạo timer nhanh từ dòng lệnh
function create_timer_from_cli() {
  if [[ $# -ne 3 ]]; then
    echo "Lỗi: Bạn cần cung cấp đủ 3 tham số: tên-timer, link/script, thời gian"
    return 1
  fi

  TIMER_NAME="$1"
  TARGET="$2"
  INTERVAL="$3"

  # Kiểm tra tên timer
  if [[ ! "$TIMER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Tên timer không hợp lệ! Chỉ được chứa chữ cái, số, dấu gạch dưới (_) và gạch ngang (-)."
    return 1
  fi

  # Kiểm tra xem timer đã tồn tại chưa
  if [[ -f "/etc/systemd/system/$TIMER_NAME.timer" || -f "/etc/systemd/system/$TIMER_NAME.service" ]]; then
    echo "Lỗi: Timer '$TIMER_NAME' đã tồn tại! Vui lòng chọn tên khác."
    return 1
  fi

  # Kiểm tra thời gian
  if [[ ! "$INTERVAL" =~ ^[0-9]+[smh]$ ]]; then
    echo "Thời gian không hợp lệ! Ví dụ hợp lệ: 1s, 10m, 1h."
    return 1
  fi

  # Kiểm tra xem TARGET là URL hay file script
  if is_valid_url "$TARGET"; then
    TYPE="curl"
    EXEC="/usr/bin/curl -s -o /dev/null \"$TARGET\""
  elif is_valid_script "$TARGET"; then
    TYPE="bash"
    EXEC="/bin/bash \"$TARGET\""
    chmod +x "$TARGET"  # Cấp quyền thực thi nếu chưa có
  else
    echo "Lỗi: TARGET không phải là URL hợp lệ hoặc file script không tồn tại/thiếu quyền thực thi!"
    return 1
  fi

  # Tạo và di chuyển các file service và timer
  SERVICE_FILE="$CONFIG_DIR/$TIMER_NAME.service"
  TIMER_FILE="$CONFIG_DIR/$TIMER_NAME.timer"

  # Tạo file service
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Run $TYPE for $TARGET

[Service]
Type=oneshot
ExecStart=$EXEC
EOF

  # Tạo file timer
  cat >"$TIMER_FILE" <<EOF
[Unit]
Description=Timer for $TARGET

[Timer]
OnUnitActiveSec=$INTERVAL
AccuracySec=1ms
Unit=$TIMER_NAME.service

[Install]
WantedBy=timers.target
EOF

  # Di chuyển file tới systemd và kích hoạt
  if ! sudo mv "$SERVICE_FILE" /etc/systemd/system/; then
    echo "Lỗi: Không thể di chuyển file service. Kiểm tra quyền sudo hoặc đường dẫn."
    return 1
  fi

  if ! sudo mv "$TIMER_FILE" /etc/systemd/system/; then
    echo "Lỗi: Không thể di chuyển file timer. Kiểm tra quyền sudo hoặc đường dẫn."
    # Nếu không di chuyển được file timer, xóa file service đã di chuyển
    sudo rm -f "/etc/systemd/system/$TIMER_NAME.service"
    return 1
  fi

  # Kiểm tra quyền thực thi
  sudo chmod 644 /etc/systemd/system/$TIMER_NAME.service
  sudo chmod 644 /etc/systemd/system/$TIMER_NAME.timer

  if ! sudo systemctl daemon-reload; then
    echo "Lỗi: Không thể tải lại daemon. Kiểm tra lại cấu hình."
    # Nếu không tải lại daemon được, xóa các file đã tạo
    sudo rm -f "/etc/systemd/system/$TIMER_NAME.service" "/etc/systemd/system/$TIMER_NAME.timer"
    return 1
  fi

  if ! sudo systemctl enable --now "$TIMER_NAME.timer"; then
    echo "Lỗi: Không thể kích hoạt timer: $TIMER_NAME"
    # Nếu không kích hoạt được, xóa các file đã tạo
    sudo rm -f "/etc/systemd/system/$TIMER_NAME.service" "/etc/systemd/system/$TIMER_NAME.timer"
    sudo systemctl daemon-reload
    return 1
  fi

  # Đảm bảo rằng service được bắt đầu
  sudo systemctl start "$TIMER_NAME.service"

  # Kiểm tra trạng thái của timer và service
  if systemctl is-active --quiet "$TIMER_NAME.timer"; then
    echo "Timer $TIMER_NAME đã được tạo và kích hoạt thành công."
  else
    echo "Lỗi: Timer $TIMER_NAME đã được tạo nhưng không kích hoạt được."
    # Nếu không kích hoạt được, xóa các file đã tạo
    sudo rm -f "/etc/systemd/system/$TIMER_NAME.service" "/etc/systemd/system/$TIMER_NAME.timer"
    sudo systemctl daemon-reload
    return 1
  fi
}

# Quản lý timer
function manage_timers() {
  while true; do
    # Cập nhật danh sách timer
    timers=$(ls /etc/systemd/system/*.timer 2>/dev/null)
    if [[ -z "$timers" ]]; then
      echo "Không có timer nào đang hoạt động."
      return
    fi

    echo "Danh sách timer hiện tại:"
    echo -e "Tên Timer             Trạng thái          Thời gian chạy             Loại"
    echo -e "---------------------------------------------------------"
    for timer in $timers; do
      timer_name=$(basename "$timer" .timer)
      if [[ -f "/etc/systemd/system/$timer_name.timer" ]]; then
        status_and_type=$(check_timer_status "$timer_name")
        interval=$(get_timer_interval "$timer_name")
        printf "%-20s %-20s %-20s %-10s\n" "$timer_name" "$status_and_type" "$interval"
      fi
    done
    echo "=================="
    read -p "Nhập tên timer cần quản lý (hoặc nhấn Enter để quay lại): " TIMER_NAME
    if [[ -z "$TIMER_NAME" ]]; then
      return
    fi

    if [[ ! -f "/etc/systemd/system/$TIMER_NAME.timer" ]]; then
      echo "Timer $TIMER_NAME không tồn tại!"
      continue
    fi

    echo "1. Dừng timer"
    echo "2. Bật lại timer"
    echo "3. Xóa timer"
    echo "4. Sửa thời gian"
    echo "5. Quay lại"
    read -p "Chọn: " CHOICE
    case $CHOICE in
    1)
      sudo systemctl stop "$TIMER_NAME.timer"
      sudo systemctl disable "$TIMER_NAME.timer"
      echo "Đã dừng timer: $TIMER_NAME"
      ;;
    2)
      sudo systemctl enable --now "$TIMER_NAME.timer"
	  sudo systemctl start "$TIMER_NAME.service"
      echo "Đã bật lại timer: $TIMER_NAME"
      ;;
    3)
      sudo systemctl stop "$TIMER_NAME.timer"
      sudo systemctl disable "$TIMER_NAME.timer"
      sudo rm -f "/etc/systemd/system/$TIMER_NAME.timer" "/etc/systemd/system/$TIMER_NAME.service"
      sudo systemctl daemon-reload
      echo "Đã xóa timer: $TIMER_NAME"
      # Cập nhật lại danh sách timer sau khi xóa
      timers=$(ls /etc/systemd/system/*.timer 2>/dev/null)
      ;;
    4)
      while true; do
        read -p "Nhập thời gian mới cho timer (ví dụ: 1s, 10s, 1m) hoặc 'back' để quay lại: " NEW_INTERVAL
        if [[ "$NEW_INTERVAL" == "back" ]]; then
          break
        fi
        if [[ "$NEW_INTERVAL" =~ ^[0-9]+[smh]$ ]]; then
          if [[ -f "/etc/systemd/system/$TIMER_NAME.timer" ]]; then
            sudo sed -i "s/OnUnitActiveSec=.*/OnUnitActiveSec=$NEW_INTERVAL/" "/etc/systemd/system/$TIMER_NAME.timer"
            sudo systemctl daemon-reload
            sudo systemctl restart "$TIMER_NAME.timer"
			sudo systemctl enable --now "$TIMER_NAME.timer"
			sudo systemctl start "$TIMER_NAME.service"
            echo "Đã thay đổi thời gian của timer $TIMER_NAME thành $NEW_INTERVAL."
          else
            echo "Không tìm thấy file timer!"
          fi
          break
        else
          echo "Lỗi: Thời gian không hợp lệ!"
        fi
      done
      ;;
    5)
      return
      ;;
    *)
      echo "Lựa chọn không hợp lệ!"
      ;;
    esac
  done
}

# Xử lý CLI
function handle_cli() {
  if [[ "$1" == "create" ]]; then
    shift
    create_timer_from_cli "$@"
  else
    echo "Lệnh không hợp lệ!"
    echo "Cách sử dụng: $0 create <tên-timer> <link> <thời gian>"
    exit 1
  fi
}

# Main script
if [[ $# -gt 0 ]]; then
  handle_cli "$@"
else
  while true; do
    show_menu
    read -p "Chọn: " CHOICE
    case $CHOICE in
    1)
      create_timer
      ;;
    2)
      manage_timers
      ;;
    3)
      echo "Thoát chương trình."
      break
      ;;
    *)
      echo "Lựa chọn không hợp lệ!"
      ;;
    esac
  done
fi
