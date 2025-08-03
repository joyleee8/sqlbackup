#!/bin/bash

# === 交互式数据库备份管理脚本 ===
# 作者: Claude
# 功能: 管理MySQL数据库备份任务

# 配置文件路径
CONFIG_DIR="/etc/db_backup"
CONFIG_FILE="$CONFIG_DIR/tasks.conf"
LOG_FILE="/var/log/db_backup.log"

# 确保配置目录存在
mkdir -p "$CONFIG_DIR"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOG_FILE"
}

# 显示彩色输出
print_color() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# 显示主菜单
show_menu() {
    clear
    print_color $BLUE "=================================="
    print_color $BLUE "    数据库备份管理系统"
    print_color $BLUE "=================================="
    echo
    print_color $GREEN "1. 新增备份任务"
    print_color $GREEN "2. 删除备份任务"
    print_color $GREEN "3. 查看所有备份任务"
    print_color $GREEN "4. 手动执行备份任务"
    print_color $GREEN "5. 网络连接诊断"
    print_color $GREEN "6. 查看备份日志"
    print_color $GREEN "7. 恢复数据库"
    print_color $YELLOW "0. 退出"
    echo
    print_color $BLUE "请选择操作: "
}

# 读取用户输入
read_input() {
    local prompt=$1
    local default=$2
    local secure=$3
    
    if [ "$secure" = "true" ]; then
        echo -n "$prompt"
        read -s input
        echo
    else
        if [ -n "$default" ]; then
            echo -n "$prompt [$default]: "
        else
            echo -n "$prompt: "
        fi
        read input
        if [ -z "$input" ] && [ -n "$default" ]; then
            input=$default
        fi
    fi
}

# 验证输入
validate_input() {
    local value=$1
    local type=$2
    
    case $type in
        "number")
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                return 1
            fi
            ;;
        "ip")
            if ! [[ "$value" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                return 1
            fi
            ;;
        "path")
            if [ ! -d "$(dirname "$value")" ]; then
                return 1
            fi
            ;;
    esac
    return 0
}

# 生成SSH密钥
setup_ssh_key() {
    local remote_user=$1
    local remote_host=$2
    local remote_pass=$3
    
    print_color $YELLOW "正在设置SSH密钥认证..."
    
    # 检查本地是否已有SSH密钥
    if [ ! -f ~/.ssh/id_rsa ]; then
        print_color $YELLOW "生成SSH密钥对..."
        ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N ""
    fi
    
    # 安装sshpass（如果没有的话）
    if ! command -v sshpass &> /dev/null; then
        print_color $YELLOW "安装sshpass工具..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y sshpass
        elif command -v yum &> /dev/null; then
            yum install -y sshpass
        else
            print_color $RED "无法自动安装sshpass，请手动安装"
            return 1
        fi
    fi
    
    # 复制公钥到远程服务器
    print_color $YELLOW "复制公钥到远程服务器..."
    if sshpass -p "$remote_pass" ssh-copy-id -o StrictHostKeyChecking=no "$remote_user@$remote_host"; then
        print_color $GREEN "SSH密钥设置成功！"
        return 0
    else
        print_color $RED "SSH密钥设置失败！"
        return 1
    fi
}

# 新增备份任务
add_backup_task() {
    clear
    print_color $BLUE "=== 新增备份任务 ==="
    echo
    
    # 读取任务名称
    while true; do
        read_input "任务名称"
        task_name=$input
        if [ -n "$task_name" ]; then
            # 检查任务名是否已存在
            if grep -q "^$task_name:" "$CONFIG_FILE" 2>/dev/null; then
                print_color $RED "任务名称已存在，请选择其他名称"
                continue
            fi
            break
        fi
        print_color $RED "任务名称不能为空"
    done
    
    # 读取数据库信息
    read_input "数据库用户名" "root"
    db_user=$input
    
    read_input "数据库密码" "" "true"
    db_pass=$input
    
    read_input "数据库名称"
    db_name=$input
    
    # 读取备份目录
    read_input "本地备份目录" "/root/db_backups"
    backup_dir=$input
    
    # 读取本地保留备份数量
    while true; do
        read_input "本地保留备份文件数量" "7"
        local_retention=$input
        if validate_input "$local_retention" "number" && [ "$local_retention" -gt 0 ]; then
            break
        fi
        print_color $RED "请输入有效的正整数"
    done
    
    # 读取远程服务器信息
    read_input "远程服务器地址"
    remote_host=$input
    
    read_input "远程服务器用户名" "root"
    remote_user=$input
    
    read_input "远程服务器目录" "/opt/backup"
    remote_dir=$input
    
    # 读取远程保留备份数量
    while true; do
        read_input "远程保留备份文件数量" "30"
        remote_retention=$input
        if validate_input "$remote_retention" "number" && [ "$remote_retention" -gt 0 ]; then
            break
        fi
        print_color $RED "请输入有效的正整数"
    done
    
    # 选择连接方式
    echo
    print_color $YELLOW "选择远程服务器连接方式:"
    print_color $GREEN "1. SSH密钥认证 推荐"
    print_color $GREEN "2. 用户名密码认证"
    
    while true; do
        read_input "请选择 1或2" "1"
        auth_method=$input
        
        case $auth_method in
            1)
                read_input "远程服务器密码 用于设置SSH密钥" "" "true"
                remote_pass=$input
                
                if setup_ssh_key "$remote_user" "$remote_host" "$remote_pass"; then
                    auth_type="ssh_key"
                    remote_pass=""  # 清空密码
                else
                    print_color $RED "SSH密钥设置失败，是否改用密码认证? y或n"
                    read choice
                    if [ "$choice" = "y" ]; then
                        auth_type="password"
                    else
                        return 1
                    fi
                fi
                break
                ;;
            2)
                read_input "远程服务器密码" "" "true"
                remote_pass=$input
                auth_type="password"
                break
                ;;
            *)
                print_color $RED "请选择1或2"
                ;;
        esac
    done
    
    # 读取备份频率
    print_color $YELLOW "设置备份频率:"
    print_color $GREEN "1. 每小时备份一次"
    print_color $GREEN "2. 每天备份一次"
    print_color $GREEN "3. 每周备份一次"
    print_color $GREEN "4. 自定义间隔分钟"
    
    while true; do
        read_input "请选择备份频率 1到4" "2"
        frequency_choice=$input
        
        case $frequency_choice in
            1)
                cron_schedule="0 * * * *"
                frequency_desc="每小时"
                break
                ;;
            2)
                print_color $YELLOW "请输入每天备份的时间24小时制:"
                while true; do
                    read_input "小时 0到23" "2"
                    backup_hour=$input
                    read_input "分钟 0到59" "0"
                    backup_minute=$input
                    
                    if validate_input "$backup_hour" "number" && [ "$backup_hour" -ge 0 ] && [ "$backup_hour" -le 23 ] && \
                       validate_input "$backup_minute" "number" && [ "$backup_minute" -ge 0 ] && [ "$backup_minute" -le 59 ]; then
                        cron_schedule="$backup_minute $backup_hour * * *"
                        frequency_desc="每天 ${backup_hour}:$(printf "%02d" $backup_minute)"
                        break
                    fi
                    print_color $RED "请输入有效的时间"
                done
                break
                ;;
            3)
                print_color $YELLOW "请选择每周备份的星期几:"
                print_color $GREEN "1=周一, 2=周二, 3=周三, 4=周四, 5=周五, 6=周六, 0=周日"
                while true; do
                    read_input "星期 0到6" "0"
                    backup_day=$input
                    read_input "小时 0到23" "2"
                    backup_hour=$input
                    read_input "分钟 0到59" "0"
                    backup_minute=$input
                    
                    if validate_input "$backup_day" "number" && [ "$backup_day" -ge 0 ] && [ "$backup_day" -le 6 ] && \
                       validate_input "$backup_hour" "number" && [ "$backup_hour" -ge 0 ] && [ "$backup_hour" -le 23 ] && \
                       validate_input "$backup_minute" "number" && [ "$backup_minute" -ge 0 ] && [ "$backup_minute" -le 59 ]; then
                        cron_schedule="$backup_minute $backup_hour * * $backup_day"
                        day_names=("周日" "周一" "周二" "周三" "周四" "周五" "周六")
                        frequency_desc="每${day_names[$backup_day]} ${backup_hour}:$(printf "%02d" $backup_minute)"
                        break
                    fi
                    print_color $RED "请输入有效的时间"
                done
                break
                ;;
            4)
                while true; do
                    read_input "备份间隔分钟数，最小5分钟" "60"
                    backup_interval=$input
                    
                    if validate_input "$backup_interval" "number" && [ "$backup_interval" -ge 5 ]; then
                        cron_schedule="*/$backup_interval * * * *"
                        frequency_desc="每${backup_interval}分钟"
                        break
                    fi
                    print_color $RED "请输入不小于5的数字"
                done
                break
                ;;
            *)
                print_color $RED "请选择1到4"
                ;;
        esac
    done
    
    # 保存任务配置
    config_line="$task_name:$db_user:$db_pass:$db_name:$backup_dir:$local_retention:$remote_host:$remote_user:$remote_pass:$remote_dir:$remote_retention:$auth_type:$cron_schedule"
    echo "$config_line" >> "$CONFIG_FILE"
    
    # 创建备份目录
    mkdir -p "$backup_dir"
    
    # 添加到crontab
    add_to_crontab "$task_name" "$cron_schedule"
    
    print_color $GREEN "备份任务 '$task_name' 创建成功！"
    print_color $BLUE "备份频率: $frequency_desc"
    log_message "创建备份任务: $task_name, 频率: $frequency_desc"
    
    echo
    print_color $BLUE "按回车键继续..."
    read
}

# 添加到crontab
add_to_crontab() {
    local task_name=$1
    local schedule=$2
    local script_path=$(realpath "$0")
    
    # 检查crontab中是否已存在该任务
    if crontab -l 2>/dev/null | grep -q "# DB_BACKUP_TASK: $task_name"; then
        return 0
    fi
    
    # 添加到crontab
    (crontab -l 2>/dev/null; echo "$schedule bash $script_path execute_task $task_name # DB_BACKUP_TASK: $task_name") | crontab -
}

# 从crontab删除任务
remove_from_crontab() {
    local task_name=$1
    crontab -l 2>/dev/null | grep -v "# DB_BACKUP_TASK: $task_name" | crontab -
}

# 删除备份任务
delete_backup_task() {
    clear
    print_color $BLUE "=== 删除备份任务 ==="
    echo
    
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        print_color $YELLOW "没有找到备份任务"
        echo
        print_color $BLUE "按回车键继续..."
        read
        return
    fi
    
    print_color $GREEN "现有备份任务:"
    echo
    local index=1
    while IFS=':' read -r task_name rest; do
        echo "$index. $task_name"
        ((index++))
    done < "$CONFIG_FILE"
    
    echo
    read_input "请输入要删除的任务编号"
    task_index=$input
    
    if ! validate_input "$task_index" "number" || [ "$task_index" -lt 1 ] || [ "$task_index" -gt $((index-1)) ]; then
        print_color $RED "无效的任务编号"
        echo
        print_color $BLUE "按回车键继续..."
        read
        return
    fi
    
    # 获取任务名
    task_name=$(sed -n "${task_index}p" "$CONFIG_FILE" | cut -d':' -f1)
    
    print_color $YELLOW "确认删除任务 '$task_name'? y或n"
    read confirmation
    
    if [ "$confirmation" = "y" ]; then
        # 从配置文件删除
        sed -i "${task_index}d" "$CONFIG_FILE"
        
        # 从crontab删除
        remove_from_crontab "$task_name"
        
        print_color $GREEN "任务 '$task_name' 已删除"
        log_message "删除备份任务: $task_name"
    else
        print_color $YELLOW "取消删除操作"
    fi
    
    echo
    print_color $BLUE "按回车键继续..."
    read
}

# 查看所有备份任务
view_backup_tasks() {
    clear
    print_color $BLUE "=== 所有备份任务 ==="
    echo
    
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        print_color $YELLOW "没有找到备份任务"
        echo
        print_color $BLUE "按回车键继续..."
        read
        return
    fi
    
    local index=1
    while IFS=':' read -r task_name db_user db_pass db_name backup_dir local_retention remote_host remote_user remote_pass remote_dir remote_retention auth_type cron_schedule; do
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print_color $GREEN "任务 $index: $task_name"
        echo "  数据库: $db_name (用户: $db_user)"
        echo "  本地目录: $backup_dir (保留: ${local_retention}个文件)"
        echo "  远程服务器: $remote_user@$remote_host:$remote_dir (保留: ${remote_retention}个文件)"
        echo "  认证方式: $([ "$auth_type" = "ssh_key" ] && echo "SSH密钥" || echo "用户名密码")"
        echo "  备份格式: 压缩文件(.sql.gz)"
        echo "  计划: $cron_schedule"
        ((index++))
    done < "$CONFIG_FILE"
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    print_color $BLUE "按回车键继续..."
    read
}

# 执行备份任务
execute_backup() {
    local task_name=$1
    local config_line=$(grep "^$task_name:" "$CONFIG_FILE")
    
    if [ -z "$config_line" ]; then
        print_color $RED "任务 '$task_name' 不存在"
        return 1
    fi
    
    # 解析配置
    IFS=':' read -r task_name db_user db_pass db_name backup_dir local_retention remote_host remote_user remote_pass remote_dir remote_retention auth_type cron_schedule <<< "$config_line"
    
    local backup_file="$backup_dir/${db_name}_$(date +%Y%m%d_%H%M%S).sql.gz"
    
    print_color $YELLOW "开始执行备份任务: $task_name"
    log_message "开始执行备份任务: $task_name"
    
    # 创建备份目录
    mkdir -p "$backup_dir"
    
    # 执行数据库备份并压缩
    print_color $YELLOW "正在备份并压缩数据库 $db_name..."
    if mysqldump -u"$db_user" -p"$db_pass" "$db_name" 2>/dev/null | gzip > "$backup_file"; then
        # 检查压缩文件是否创建成功且大小大于0
        if [ -s "$backup_file" ]; then
            local file_size=$(du -h "$backup_file" | cut -f1)
            print_color $GREEN "数据库备份成功: $backup_file (大小: $file_size)"
            log_message "数据库备份成功: $backup_file (大小: $file_size)"
        else
            print_color $RED "备份文件为空，备份可能失败"
            log_message "数据库备份失败: 备份文件为空"
            rm -f "$backup_file"
            return 1
        fi
    else
        print_color $RED "数据库备份失败"
        log_message "数据库备份失败: $task_name"
        rm -f "$backup_file"
        return 1
    fi
    
    # 传输到远程服务器
    print_color $YELLOW "正在传输到远程服务器..."
    
    # 先测试远程连接
    print_color $YELLOW "测试远程连接..."
    if [ "$auth_type" = "ssh_key" ]; then
        if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$remote_user@$remote_host" "echo 'SSH连接测试成功'" 2>/dev/null; then
            print_color $GREEN "SSH连接测试成功"
        else
            print_color $RED "SSH连接失败，请检查网络和SSH密钥配置"
            log_message "SSH连接失败: $remote_user@$remote_host"
            return 1
        fi
    else
        if sshpass -p "$remote_pass" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$remote_user@$remote_host" "echo 'SSH连接测试成功'" 2>/dev/null; then
            print_color $GREEN "SSH连接测试成功"
        else
            print_color $RED "SSH连接失败，请检查网络、用户名和密码"
            log_message "SSH连接失败: $remote_user@$remote_host (用户名密码认证)"
            return 1
        fi
    fi
    
    # 检查并创建远程目录
    print_color $YELLOW "检查远程目录..."
    if [ "$auth_type" = "ssh_key" ]; then
        if ssh -o StrictHostKeyChecking=no "$remote_user@$remote_host" "mkdir -p '$remote_dir' && test -w '$remote_dir'" 2>/dev/null; then
            print_color $GREEN "远程目录检查成功: $remote_dir"
        else
            print_color $RED "远程目录创建失败或无写权限: $remote_dir"
            log_message "远程目录问题: $remote_dir"
            return 1
        fi
    else
        if sshpass -p "$remote_pass" ssh -o StrictHostKeyChecking=no "$remote_user@$remote_host" "mkdir -p '$remote_dir' && test -w '$remote_dir'" 2>/dev/null; then
            print_color $GREEN "远程目录检查成功: $remote_dir"
        else
            print_color $RED "远程目录创建失败或无写权限: $remote_dir"
            log_message "远程目录问题: $remote_dir"
            return 1
        fi
    fi
    
    # 执行文件传输
    print_color $YELLOW "正在上传备份文件..."
    local transfer_error=""
    if [ "$auth_type" = "ssh_key" ]; then
        transfer_error=$(scp -o StrictHostKeyChecking=no "$backup_file" "$remote_user@$remote_host:$remote_dir/" 2>&1)
        transfer_result=$?
    else
        transfer_error=$(sshpass -p "$remote_pass" scp -o StrictHostKeyChecking=no "$backup_file" "$remote_user@$remote_host:$remote_dir/" 2>&1)
        transfer_result=$?
    fi
    
    if [ $transfer_result -eq 0 ]; then
        print_color $GREEN "文件传输成功"
        log_message "文件传输成功到: $remote_user@$remote_host:$remote_dir/"
        
        # 验证文件是否真的传输成功
        local remote_file="$remote_dir/$(basename "$backup_file")"
        if [ "$auth_type" = "ssh_key" ]; then
            if ssh -o StrictHostKeyChecking=no "$remote_user@$remote_host" "test -f '$remote_file'" 2>/dev/null; then
                print_color $GREEN "文件验证成功"
            else
                print_color $YELLOW "警告：文件可能传输不完整"
                log_message "文件验证失败: $remote_file"
            fi
        else
            if sshpass -p "$remote_pass" ssh -o StrictHostKeyChecking=no "$remote_user@$remote_host" "test -f '$remote_file'" 2>/dev/null; then
                print_color $GREEN "文件验证成功"
            else
                print_color $YELLOW "警告：文件可能传输不完整"
                log_message "文件验证失败: $remote_file"
            fi
        fi
    else
        print_color $RED "文件传输失败"
        print_color $RED "错误信息: $transfer_error"
        log_message "文件传输失败: $task_name - 错误: $transfer_error"
        return 1
    fi
    
    # 清理本地旧备份
    print_color $YELLOW "清理本地旧备份文件..."
    local backup_count=$(find "$backup_dir" -type f -name "*.sql.gz" | wc -l)
    if [ "$backup_count" -gt "$local_retention" ]; then
        local files_to_delete=$((backup_count - local_retention))
        print_color $YELLOW "当前有 $backup_count 个备份文件，保留最新 $local_retention 个，删除 $files_to_delete 个旧文件"
        find "$backup_dir" -type f -name "*.sql.gz" -printf '%T@ %p\n' | sort -n | head -n "$files_to_delete" | cut -d' ' -f2- | xargs rm -f
        log_message "清理本地备份文件: 删除了 $files_to_delete 个旧文件，保留最新 $local_retention 个"
    else
        print_color $GREEN "本地备份文件数量 ($backup_count) 未超过保留数量 ($local_retention)，无需清理"
        log_message "本地备份文件无需清理，当前数量: $backup_count"
    fi
    
    # 清理远程旧备份
    print_color $YELLOW "清理远程旧备份文件..."
    local cleanup_cmd="
    cd '$remote_dir' 2>/dev/null || exit 1
    backup_count=\$(find . -maxdepth 1 -type f -name '*.sql.gz' | wc -l)
    if [ \"\$backup_count\" -gt \"$remote_retention\" ]; then
        files_to_delete=\$((backup_count - $remote_retention))
        echo \"远程备份清理: 当前\$backup_count个文件，保留$remote_retention个，删除\$files_to_delete个\"
        find . -maxdepth 1 -type f -name '*.sql.gz' -printf '%T@ %p\n' | sort -n | head -n \"\$files_to_delete\" | cut -d' ' -f2- | xargs rm -f
    else
        echo \"远程备份无需清理，当前数量: \$backup_count\"
    fi
    "
    
    local cleanup_result=""
    if [ "$auth_type" = "ssh_key" ]; then
        cleanup_result=$(ssh "$remote_user@$remote_host" "$cleanup_cmd" 2>&1)
    else
        cleanup_result=$(sshpass -p "$remote_pass" ssh -o StrictHostKeyChecking=no "$remote_user@$remote_host" "$cleanup_cmd" 2>&1)
    fi
    
    if [ $? -eq 0 ]; then
        print_color $GREEN "$cleanup_result"
        log_message "远程备份清理完成: $cleanup_result"
    else
        print_color $YELLOW "远程备份清理可能失败: $cleanup_result"
        log_message "远程备份清理失败: $cleanup_result"
    fi
    
    print_color $GREEN "备份任务 '$task_name' 执行完成"
    log_message "备份任务执行完成: $task_name"
}

# 手动执行备份任务
manual_execute_task() {
    clear
    print_color $BLUE "=== 手动执行备份任务 ==="
    echo
    
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        print_color $YELLOW "没有找到备份任务"
        echo
        print_color $BLUE "按回车键继续..."
        read
        return
    fi
    
    print_color $GREEN "现有备份任务:"
    echo
    local index=1
    while IFS=':' read -r task_name rest; do
        echo "$index. $task_name"
        ((index++))
    done < "$CONFIG_FILE"
    
    echo
    read_input "请输入要执行的任务编号"
    task_index=$input
    
    if ! validate_input "$task_index" "number" || [ "$task_index" -lt 1 ] || [ "$task_index" -gt $((index-1)) ]; then
        print_color $RED "无效的任务编号"
        echo
        print_color $BLUE "按回车键继续..."
        read
        return
    fi
    
    # 获取任务名
    task_name=$(sed -n "${task_index}p" "$CONFIG_FILE" | cut -d':' -f1)
    
    execute_backup "$task_name"
    
    echo
    print_color $BLUE "按回车键继续..."
    read
}

# 网络诊断功能
diagnose_connection() {
    local task_name=$1
    local config_line=$(grep "^$task_name:" "$CONFIG_FILE")
    
    if [ -z "$config_line" ]; then
        print_color $RED "任务 '$task_name' 不存在"
        return 1
    fi
    
    # 解析配置
    IFS=':' read -r task_name db_user db_pass db_name backup_dir local_retention remote_host remote_user remote_pass remote_dir remote_retention auth_type cron_schedule <<< "$config_line"
    
    clear
    print_color $BLUE "=== 网络连接诊断 ==="
    echo
    print_color $YELLOW "诊断任务: $task_name"
    print_color $YELLOW "远程服务器: $remote_user@$remote_host"
    print_color $YELLOW "认证方式: $([ "$auth_type" = "ssh_key" ] && echo "SSH密钥" || echo "用户名密码")"
    echo
    
    # 1. 基础网络连通性测试
    print_color $YELLOW "1. 测试网络连通性..."
    if ping -c 3 -W 5 "$remote_host" >/dev/null 2>&1; then
        print_color $GREEN "✓ 网络连通正常"
    else
        print_color $RED "✗ 网络不通，请检查网络连接和服务器地址"
        return 1
    fi
    
    # 2. SSH端口测试
    print_color $YELLOW "2. 测试SSH端口22..."
    if timeout 10 bash -c "</dev/tcp/$remote_host/22" 2>/dev/null; then
        print_color $GREEN "✓ SSH端口22可达"
    else
        print_color $RED "✗ SSH端口22不可达，请检查防火墙设置"
        return 1
    fi
    
    # 3. SSH认证测试
    print_color $YELLOW "3. 测试SSH认证..."
    if [ "$auth_type" = "ssh_key" ]; then
        # 检查本地SSH密钥
        if [ ! -f ~/.ssh/id_rsa ]; then
            print_color $RED "✗ 本地SSH私钥不存在"
            return 1
        fi
        
        # 测试SSH密钥认证
        if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o PasswordAuthentication=no "$remote_user@$remote_host" "echo 'SSH密钥认证成功'" 2>/dev/null; then
            print_color $GREEN "✓ SSH密钥认证成功"
        else
            print_color $RED "✗ SSH密钥认证失败"
            print_color $YELLOW "可能的原因："
            echo "   - 公钥未正确复制到远程服务器"
            echo "   - 远程服务器的authorized_keys文件权限不正确"
            echo "   - SSH服务配置不允许密钥认证"
            return 1
        fi
    else
        # 测试密码认证
        if sshpass -p "$remote_pass" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$remote_user@$remote_host" "echo '密码认证成功'" 2>/dev/null; then
            print_color $GREEN "✓ 密码认证成功"
        else
            print_color $RED "✗ 密码认证失败"
            print_color $YELLOW "可能的原因："
            echo "   - 用户名或密码错误"
            echo "   - 远程用户账户被锁定或禁用"
            echo "   - SSH服务配置不允许密码认证"
            return 1
        fi
    fi
    
    # 4. 远程目录权限测试
    print_color $YELLOW "4. 测试远程目录权限..."
    local test_cmd="mkdir -p '$remote_dir' && test -w '$remote_dir' && echo '目录权限正常'"
    local result=""
    
    if [ "$auth_type" = "ssh_key" ]; then
        result=$(ssh -o StrictHostKeyChecking=no "$remote_user@$remote_host" "$test_cmd" 2>&1)
    else
        result=$(sshpass -p "$remote_pass" ssh -o StrictHostKeyChecking=no "$remote_user@$remote_host" "$test_cmd" 2>&1)
    fi
    
    if echo "$result" | grep -q "目录权限正常"; then
        print_color $GREEN "✓ 远程目录权限正常"
    else
        print_color $RED "✗ 远程目录权限问题"
        print_color $YELLOW "错误信息: $result"
        return 1
    fi
    
    # 5. 文件传输测试
    print_color $YELLOW "5. 测试文件传输..."
    local test_file="/tmp/test_backup_$(date +%s).txt.gz"
    echo "测试文件内容" | gzip > "$test_file"
    
    local transfer_result=""
    if [ "$auth_type" = "ssh_key" ]; then
        transfer_result=$(scp -o StrictHostKeyChecking=no "$test_file" "$remote_user@$remote_host:$remote_dir/" 2>&1)
        scp_status=$?
    else
        transfer_result=$(sshpass -p "$remote_pass" scp -o StrictHostKeyChecking=no "$test_file" "$remote_user@$remote_host:$remote_dir/" 2>&1)
        scp_status=$?
    fi
    
    if [ $scp_status -eq 0 ]; then
        print_color $GREEN "✓ 文件传输测试成功"
        # 清理测试文件
        rm -f "$test_file"
        if [ "$auth_type" = "ssh_key" ]; then
            ssh -o StrictHostKeyChecking=no "$remote_user@$remote_host" "rm -f '$remote_dir/$(basename "$test_file")'" 2>/dev/null
        else
            sshpass -p "$remote_pass" ssh -o StrictHostKeyChecking=no "$remote_user@$remote_host" "rm -f '$remote_dir/$(basename "$test_file")'" 2>/dev/null
        fi
    else
        print_color $RED "✗ 文件传输测试失败"
        print_color $YELLOW "错误信息: $transfer_result"
        rm -f "$test_file"
        return 1
    fi
    
    print_color $GREEN "✓ 所有诊断测试通过！"
    echo
}

# 网络诊断菜单
network_diagnosis_menu() {
    clear
    print_color $BLUE "=== 网络连接诊断 ==="
    echo
    
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        print_color $YELLOW "没有找到备份任务"
        echo
        print_color $BLUE "按回车键继续..."
        read
        return
    fi
    
    print_color $GREEN "选择要诊断的备份任务:"
    echo
    local index=1
    while IFS=':' read -r task_name rest; do
        echo "$index. $task_name"
        ((index++))
    done < "$CONFIG_FILE"
    
    echo
    read_input "请输入任务编号"
    task_index=$input
    
    if ! validate_input "$task_index" "number" || [ "$task_index" -lt 1 ] || [ "$task_index" -gt $((index-1)) ]; then
        print_color $RED "无效的任务编号"
        echo
        print_color $BLUE "按回车键继续..."
        read
        return
    fi
    
    # 获取任务名
    task_name=$(sed -n "${task_index}p" "$CONFIG_FILE" | cut -d':' -f1)
    
    diagnose_connection "$task_name"
    
    echo
    print_color $BLUE "按回车键继续..."
    read
}

# 数据库恢复功能
restore_database() {
    clear
    print_color $BLUE "=== 数据库恢复 ==="
    echo
    
    # 选择恢复方式
    print_color $YELLOW "选择恢复方式:"
    print_color $GREEN "1. 从本地备份文件恢复"
    print_color $GREEN "2. 从远程服务器下载并恢复"
    
    while true; do
        read_input "请选择 1或2" "1"
        restore_choice=$input
        
        case $restore_choice in
            1)
                restore_from_local
                break
                ;;
            2)
                restore_from_remote
                break
                ;;
            *)
                print_color $RED "请选择1或2"
                ;;
        esac
    done
    
    echo
    print_color $BLUE "按回车键继续..."
    read
}

# 从本地恢复
restore_from_local() {
    print_color $YELLOW "本地备份文件恢复"
    echo
    
    # 列出所有备份目录
    print_color $GREEN "可用的备份目录:"
    local dirs=()
    local index=1
    
    if [ -f "$CONFIG_FILE" ]; then
        while IFS=':' read -r task_name db_user db_pass db_name backup_dir rest; do
            if [ -d "$backup_dir" ]; then
                dirs+=("$backup_dir")
                echo "$index. $backup_dir (任务: $task_name)"
                ((index++))
            fi
        done < "$CONFIG_FILE"
    fi
    
    # 如果没有配置目录，允许手动输入
    if [ ${#dirs[@]} -eq 0 ]; then
        read_input "请输入备份目录路径"
        backup_dir=$input
        if [ ! -d "$backup_dir" ]; then
            print_color $RED "目录不存在: $backup_dir"
            return 1
        fi
        dirs+=("$backup_dir")
        index=2
    fi
    
    # 选择备份目录
    if [ ${#dirs[@]} -gt 1 ]; then
        while true; do
            read_input "请选择备份目录编号 1到$((index-1))"
            dir_choice=$input
            if validate_input "$dir_choice" "number" && [ "$dir_choice" -ge 1 ] && [ "$dir_choice" -lt $index ]; then
                backup_dir=${dirs[$((dir_choice-1))]}
                break
            fi
            print_color $RED "无效的选择"
        done
    else
        backup_dir=${dirs[0]}
    fi
    
    # 列出备份文件
    print_color $YELLOW "在目录 $backup_dir 中找到的备份文件:"
    local backup_files=($(find "$backup_dir" -name "*.sql.gz" -type f | sort -r))
    
    if [ ${#backup_files[@]} -eq 0 ]; then
        print_color $RED "没有找到备份文件(.sql.gz)"
        return 1
    fi
    
    # 显示备份文件列表
    for i in "${!backup_files[@]}"; do
        local file=${backup_files[$i]}
        local size=$(du -h "$file" | cut -f1)
        local date=$(stat -c %y "$file" | cut -d' ' -f1,2 | cut -d'.' -f1)
        echo "$((i+1)). $(basename "$file") (大小: $size, 时间: $date)"
    done
    
    # 选择备份文件
    while true; do
        read_input "请选择要恢复的备份文件编号 1到${#backup_files[@]}"
        file_choice=$input
        if validate_input "$file_choice" "number" && [ "$file_choice" -ge 1 ] && [ "$file_choice" -le ${#backup_files[@]} ]; then
            selected_file=${backup_files[$((file_choice-1))]}
            break
        fi
        print_color $RED "无效的选择"
    done
    
    # 执行恢复
    perform_restore "$selected_file"
}

# 从远程服务器恢复
restore_from_remote() {
    print_color $YELLOW "从远程服务器恢复"
    echo
    
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        print_color $YELLOW "没有找到备份任务配置"
        echo
        return
    fi
    
    # 选择备份任务
    print_color $GREEN "选择备份任务:"
    local index=1
    while IFS=':' read -r task_name rest; do
        echo "$index. $task_name"
        ((index++))
    done < "$CONFIG_FILE"
    
    while true; do
        read_input "请选择任务编号 1到$((index-1))"
        task_choice=$input
        if validate_input "$task_choice" "number" && [ "$task_choice" -ge 1 ] && [ "$task_choice" -lt $index ]; then
            break
        fi
        print_color $RED "无效的选择"
    done
    
    # 获取任务配置
    local config_line=$(sed -n "${task_choice}p" "$CONFIG_FILE")
    IFS=':' read -r task_name db_user db_pass db_name backup_dir local_retention remote_host remote_user remote_pass remote_dir remote_retention auth_type cron_schedule <<< "$config_line"
    
    # 列出远程备份文件
    print_color $YELLOW "获取远程备份文件列表..."
    local list_cmd="find '$remote_dir' -name '*.sql.gz' -type f -printf '%T@ %p %s\n' | sort -rn"
    local remote_files=""
    
    if [ "$auth_type" = "ssh_key" ]; then
        remote_files=$(ssh -o StrictHostKeyChecking=no "$remote_user@$remote_host" "$list_cmd" 2>/dev/null)
    else
        remote_files=$(sshpass -p "$remote_pass" ssh -o StrictHostKeyChecking=no "$remote_user@$remote_host" "$list_cmd" 2>/dev/null)
    fi
    
    if [ -z "$remote_files" ]; then
        print_color $RED "没有找到远程备份文件"
        return 1
    fi
    
    # 显示远程文件列表
    print_color $GREEN "远程备份文件:"
    local file_index=1
    declare -a remote_file_paths
    
    while IFS=' ' read -r timestamp filepath filesize; do
        if [ -n "$filepath" ]; then
            local filename=$(basename "$filepath")
            local date=$(date -d "@$timestamp" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "未知时间")
            local size_mb=$((filesize / 1024 / 1024))
            echo "$file_index. $filename (大小: ${size_mb}MB, 时间: $date)"
            remote_file_paths+=("$filepath")
            ((file_index++))
        fi
    done <<< "$remote_files"
    
    # 选择要下载的文件
    while true; do
        read_input "请选择要恢复的备份文件编号 1到$((file_index-1))"
        file_choice=$input
        if validate_input "$file_choice" "number" && [ "$file_choice" -ge 1 ] && [ "$file_choice" -lt $file_index ]; then
            selected_remote_file=${remote_file_paths[$((file_choice-1))]}
            break
        fi
        print_color $RED "无效的选择"
    done
    
    # 下载文件
    local temp_file="/tmp/$(basename "$selected_remote_file")"
    print_color $YELLOW "正在下载备份文件..."
    
    if [ "$auth_type" = "ssh_key" ]; then
        if scp -o StrictHostKeyChecking=no "$remote_user@$remote_host:$selected_remote_file" "$temp_file" 2>/dev/null; then
            print_color $GREEN "文件下载成功"
        else
            print_color $RED "文件下载失败"
            return 1
        fi
    else
        if sshpass -p "$remote_pass" scp -o StrictHostKeyChecking=no "$remote_user@$remote_host:$selected_remote_file" "$temp_file" 2>/dev/null; then
            print_color $GREEN "文件下载成功"
        else
            print_color $RED "文件下载失败"
            return 1
        fi
    fi
    
    # 执行恢复
    perform_restore "$temp_file" "true"
}

# 执行数据库恢复
perform_restore() {
    local backup_file=$1
    local is_temp_file=${2:-false}
    
    echo
    print_color $YELLOW "准备恢复数据库..."
    
    # 获取数据库连接信息
    read_input "数据库用户名" "root"
    restore_db_user=$input
    
    read_input "数据库密码" "" "true"
    restore_db_pass=$input
    
    read_input "目标数据库名"
    restore_db_name=$input
    
    # 确认操作
    print_color $RED "警告: 此操作将覆盖数据库 '$restore_db_name' 的所有数据!"
    read_input "确认执行恢复? yes或no" "no"
    
    if [ "$input" != "yes" ]; then
        print_color $YELLOW "恢复操作已取消"
        if [ "$is_temp_file" = "true" ]; then
            rm -f "$backup_file"
        fi
        return 0
    fi
    
    # 执行恢复
    print_color $YELLOW "正在恢复数据库..."
    if zcat "$backup_file" | mysql -u"$restore_db_user" -p"$restore_db_pass" "$restore_db_name" 2>/dev/null; then
        print_color $GREEN "数据库恢复成功!"
        log_message "数据库恢复成功: $restore_db_name from $(basename "$backup_file")"
    else
        print_color $RED "数据库恢复失败"
        log_message "数据库恢复失败: $restore_db_name from $(basename "$backup_file")"
    fi
    
    # 清理临时文件
    if [ "$is_temp_file" = "true" ]; then
        rm -f "$backup_file"
        print_color $YELLOW "临时文件已清理"
    fi
}

# 查看备份日志
view_logs() {
    clear
    print_color $BLUE "=== 备份日志 ==="
    echo
    
    if [ ! -f "$LOG_FILE" ]; then
        print_color $YELLOW "没有找到日志文件"
    else
        print_color $GREEN "最近20条日志记录:"
        echo
        tail -20 "$LOG_FILE"
    fi
    
    echo
    print_color $BLUE "按回车键继续..."
    read
}

# 主程序
main() {
    # 检查是否以root权限运行
    if [ "$EUID" -ne 0 ]; then
        print_color $RED "请以root权限运行此脚本"
        exit 1
    fi
    
    # 检查是否为定时任务执行
    if [ "$1" = "execute_task" ] && [ -n "$2" ]; then
        execute_backup "$2"
        exit 0
    fi
    
    while true; do
        show_menu
        read choice
        
        case $choice in
            1)
                add_backup_task
                ;;
            2)
                delete_backup_task
                ;;
            3)
                view_backup_tasks
                ;;
            4)
                manual_execute_task
                ;;
            5)
                print_color $YELLOW "正在启动网络诊断..."
                network_diagnosis_menu
                ;;
            6)
                view_logs
                ;;
            7)
                restore_database
                ;;
            0)
                print_color $GREEN "感谢使用数据库备份管理系统！"
                exit 0
                ;;
            *)
                print_color $RED "无效选择，请重新输入"
                sleep 1
                ;;
        esac
    done
}

# 启动程序
main "$@"