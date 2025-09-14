# WebDAV 分段并行备份脚本 (WebDAV Segmented Parallel Backup Script)

[![Language](https://img.shields.io/badge/Language-Bash-blue.svg)](https://www.gnu.org/software/bash/)

一个强大且自动化的 Bash 脚本，用于将大型目录备份到支持 WebDAV 协议的云存储服务（如 123云盘、坚果云、Nextcloud 等）。

该脚本特别适用于以下场景：
*   需要备份的数据量巨大（例如 Minecraft 服务器存档、网站文件等）。
*   目标云存储对单个上传文件有大小限制。
*   服务器出口带宽有限，希望通过并行上传来最大化利用带宽，缩短备份时间。

---

## ✨ 功能特性 (Features)

*   **🗜️ 分段压缩与上传:** 自动将源目录打包压缩，并分割成指定大小的段文件，突破单文件上传限制。
*   **🚀 并行上传:** 同时上传多个分段文件，显著减少总备份耗时，充分利用服务器带宽。
*   **🧹 自动保留策略:** 自动清理云端的旧备份，仅保留最近的 N 份备份，有效管理存储空间。
*   **🛡️ 安全优先:** 通过环境变量读取 WebDAV 用户名和密码，避免在脚本中硬编码敏感信息。
*   **📄 详细日志:** 记录每个关键步骤，包括压缩、上传（含进程ID）、清理等，方便追踪和排错。
*   **💪 健壮可靠:** 包含完整的依赖检查、配置验证和错误处理机制，确保任务稳定运行。

---

## 🔧 环境要求 (Requirements)

确保您的 Linux 系统上安装了以下命令行工具：
*   `bash` (v4.0 或更高版本)
*   `curl`
*   `tar`
*   `split`
*   `basename`

---

## 🚀 如何使用 (How to Use)

### 1. 下载脚本

```bash
git clone https://github.com/lansepeach/WebDAV-Backup.git
cd your-repo-name
# 或者直接下载脚本文件
# wget https://raw.githubusercontent.com/lansepeach/WebDAV-Backup/refs/heads/main/webdav-backup.sh
```

### 2. 添加执行权限

```bash
chmod +x webdav-backup.sh
```

### 3. 配置脚本

直接编辑 `webdav-backup.sh` 文件顶部的 **`--- Configuration Section ---`** 区域：

| 变量名 | 说明 | 示例 |
| :--- | :--- | :--- |
| `SOURCE_DIR` | **【必填】** 需要备份的源目录的绝对路径。 | `"/opt/mcsmanager/daemon/data/InstanceData/..."` |
| `TEMP_DIR` | **【必填】** 用于存放临时分段文件的目录。请确保有足够空间。 | `"/tmp/webdav_backup_temp"` |
| `SEGMENT_SIZE` | 每个分段文件的大小。建议略小于云盘限制。 | `"950M"` |
| `WEBDAV_URL` | **【必填】** 你的 WebDAV 目标目录的完整 URL，**必须以 `/` 结尾**。 | `"https://webdav.123pan.cn/webdav/my_backups/"` |
| `RETENTION_COUNT`| 希望在云端保留的最新备份数量。 | `7` |
| `EXCLUDES` | 压缩时需要排除的文件或目录，用空格分隔。 | `"--exclude='./cache' --exclude='./logs'"` |
| `MAX_PARALLEL_UPLOADS` | 同时上传的最大任务数。 | `4` |

### 4. 设置环境变量（重要！）

为了安全，脚本从环境变量中读取 WebDAV 凭据。**请不要将用户名和密码直接写入脚本。**

**临时设置 (仅对当前终端会话有效):**
```bash
export WEBDAV_USER="你的WebDAV用户名"
export WEBDAV_PASS="你的WebDAV密码"
```

**永久设置 (推荐用于自动化任务):**
将上述 `export` 命令添加到您系统的 `~/.bashrc`, `~/.profile` 或 `/etc/profile` 文件末尾，然后执行 `source ~/.bashrc` 使其生效。

### 5. 执行脚本

**手动执行:**
```bash
# 确保已设置环境变量
./webdav-backup.sh
```

**通过 Cron 或 MCSManager 自动化执行:**
在 MCSManager 的计划任务中，执行命令应设置为：
```bash
/bin/bash /path/to/your/webdav-backup.sh
```
**重要:** Cron 或 MCSManager 等自动化工具默认可能不会加载用户的 `.bashrc` 文件。为确保脚本能读取到环境变量，最佳实践是创建一个启动脚本，或者在任务命令中直接定义它们：
```bash
WEBDAV_USER="你的用户名" WEBDAV_PASS="你的密码" /bin/bash /path/to/webdav-backup-manager.sh
```

---

## 📦 如何恢复备份 (How to Restore)

1.  从您的 WebDAV 服务器下载属于同一次备份的所有分段文件 (例如 `...part_aa`, `...part_ab`, `...part_ac` 等) 到同一个目录下。

2.  使用 `cat` 命令将所有分段文件合并成一个完整的压缩包：
    ```bash
    cat mcsmanager_backup_YYYYMMDDHHMMSS.tar.gz.part_* > mcsmanager_backup_complete.tar.gz
    ```

3.  解压恢复文件：
    ```bash
    tar -xzf mcsmanager_backup_complete.tar.gz
    ```

---

## 📄 许可证 (License)

本项目采用 [MIT License](LICENSE) 授权。
