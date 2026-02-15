import subprocess
import json
import time
import requests
from datetime import datetime
import os
import pickle
from collections import defaultdict
import urllib3

# 禁用SSL警告
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


class MultiUserKubernetesMonitor:
    def __init__(self, telegram_bot_token, namespace, data_dir='monitor_data'):
        self.bot_token = telegram_bot_token
        self.namespace = namespace
        self.data_dir = data_dir

        # 创建数据目录
        os.makedirs(data_dir, exist_ok=True)

        # 用户配置：{chat_id: {filters, job_states}}
        self.users = {}

        # 用户待输入状态：{chat_id: 'add_keyword' | 'remove_keyword' | ...}
        self.pending_action = {}

        # 缓存: 所有pods的最新快照，避免每个用户都调用kubectl
        self._cached_pods = []
        self._cache_time = 0
        self._cache_ttl = 10  # 缓存10秒

        # 加载所有用户配置
        self.load_all_users()

    # ── persistence ──────────────────────────────────────────────

    def load_all_users(self):
        """加载所有用户的配置"""
        user_files = [
            f for f in os.listdir(self.data_dir)
            if f.startswith('user_') and f.endswith('.pkl')
        ]
        for user_file in user_files:
            chat_id = user_file.replace('user_', '').replace('.pkl', '')
            self.load_user_config(chat_id)
        print(f"✅ Loaded {len(self.users)} users")

    def load_user_config(self, chat_id):
        """加载单个用户的配置"""
        config_file = os.path.join(self.data_dir, f'user_{chat_id}.pkl')
        if os.path.exists(config_file):
            try:
                with open(config_file, 'rb') as f:
                    config = pickle.load(f)
                    self.users[chat_id] = config
                print(f"  Loaded user {chat_id}: {config.get('filters', {}).get('keywords', [])}")
            except Exception as e:
                print(f"❌ Error loading user {chat_id}: {e}")
                self.users[chat_id] = self._default_config()
        else:
            self.users[chat_id] = self._default_config()

    def save_user_config(self, chat_id):
        """保存单个用户的配置"""
        config_file = os.path.join(self.data_dir, f'user_{chat_id}.pkl')
        try:
            with open(config_file, 'wb') as f:
                pickle.dump(self.users[chat_id], f)
        except Exception as e:
            print(f"❌ Error saving user {chat_id}: {e}")

    @staticmethod
    def _default_config():
        return {
            'filters': {
                'keywords': [],
                'exclude_keywords': [],
            },
            'job_states': {},
            'created_at': datetime.now().isoformat(),
        }

    # ── kubectl / pod helpers ────────────────────────────────────

    def _fetch_all_pods(self):
        """调用kubectl获取namespace下所有pods，带简单缓存"""
        now = time.time()
        if now - self._cache_time < self._cache_ttl and self._cached_pods is not None:
            return self._cached_pods

        try:
            result = subprocess.run(
                ['kubectl', 'get', 'pods', '-n', self.namespace, '-o', 'json'],
                capture_output=True, text=True, timeout=30,
            )
            if result.returncode != 0:
                print(f"❌ kubectl error: {result.stderr}")
                return self._cached_pods or []

            data = json.loads(result.stdout)
            pods = []
            for pod in data.get('items', []):
                meta = pod.get('metadata', {})
                pods.append({
                    'name': meta.get('name', ''),
                    'job_name': meta.get('labels', {}).get('job-name', meta.get('name', '')),
                    'phase': pod.get('status', {}).get('phase', 'Unknown'),
                    'uid': meta.get('uid', meta.get('name', '')),
                })

            self._cached_pods = pods
            self._cache_time = now
            return pods

        except Exception as e:
            print(f"❌ Exception fetching pods: {e}")
            return self._cached_pods or []

    def matches_filters(self, pod_name, chat_id):
        """检查pod是否匹配用户的过滤条件（按 '-' 分段精确匹配）"""
        if chat_id not in self.users:
            return False

        filters = self.users[chat_id]['filters']

        if not filters['keywords']:
            return False

        # 按 '-' 分段，精确匹配段
        segments = pod_name.lower().split('-')

        keyword_match = any(kw.lower() in segments for kw in filters['keywords'])
        if not keyword_match:
            return False

        # 排除关键词（同样按段匹配）
        if filters['exclude_keywords']:
            if any(kw.lower() in segments for kw in filters['exclude_keywords']):
                return False

        return True

    def get_filtered_pods_for_user(self, chat_id):
        """获取符合用户过滤条件的pods（实时查询）"""
        all_pods = self._fetch_all_pods()
        return [p for p in all_pods if self.matches_filters(p['name'], chat_id)]

    # ── telegram helpers ─────────────────────────────────────────

    def send_telegram_message(self, chat_id, message, parse_mode="Markdown"):
        url = f"https://api.telegram.org/bot{self.bot_token}/sendMessage"
        data = {"chat_id": chat_id, "text": message, "parse_mode": parse_mode}
        try:
            resp = requests.post(url, json=data, timeout=10, verify=False)
            if resp.status_code != 200:
                print(f"❌ Send failed to {chat_id}: {resp.text}")
            return resp.status_code == 200
        except Exception as e:
            print(f"❌ Send exception to {chat_id}: {e}")
            return False

    def check_telegram_messages(self):
        """轮询Telegram更新"""
        url = f"https://api.telegram.org/bot{self.bot_token}/getUpdates"
        params = {
            "offset": getattr(self, 'last_update_id', 0) + 1,
            "timeout": 1,
        }
        try:
            resp = requests.get(url, params=params, timeout=5, verify=False)
            if resp.status_code != 200:
                return
            data = resp.json()
            if not data.get('ok'):
                return

            for update in data.get('result', []):
                self.last_update_id = update['update_id']
                message = update.get('message', {})
                chat_id = str(message.get('chat', {}).get('id', ''))
                if not chat_id:
                    continue
                text = message.get('text', '')
                if not text:
                    continue

                if text.startswith('/'):
                    self.pending_action.pop(chat_id, None)
                    reply = self.handle_command(chat_id, text)
                    if reply:
                        self.send_telegram_message(chat_id, reply)
                elif chat_id in self.pending_action:
                    reply = self.handle_pending_input(chat_id, text.strip())
                    if reply:
                        self.send_telegram_message(chat_id, reply)

        except Exception as e:
            print(f"❌ Error checking messages: {e}")

    # ── command dispatch ─────────────────────────────────────────

    def handle_command(self, chat_id, command_text):
        command_text = command_text.strip()
        print(f"📨 User {chat_id}: {command_text}")

        if chat_id not in self.users:
            self.load_user_config(chat_id)

        cmd = command_text.split()[0].lower()
        # strip @botname suffix (e.g. /status@MyBot)
        cmd = cmd.split('@')[0]
        rest = command_text.split(maxsplit=1)[1] if len(command_text.split(maxsplit=1)) > 1 else None

        dispatch = {
            '/start':          lambda: self.cmd_start(chat_id),
            '/status':         lambda: self.cmd_status(chat_id),
            '/add_keyword':    lambda: self.cmd_add_keyword(chat_id, rest),
            '/remove_keyword': lambda: self.cmd_remove_keyword(chat_id, rest),
            '/add_exclude':    lambda: self.cmd_add_exclude(chat_id, rest),
            '/remove_exclude': lambda: self.cmd_remove_exclude(chat_id, rest),
            '/clear_filters':  lambda: self.cmd_clear_filters(chat_id),
            '/list_pods':      lambda: self.cmd_list_pods(chat_id),
            '/help':           lambda: self.cmd_help(),
        }

        handler = dispatch.get(cmd)
        if handler:
            return handler()
        return "❌ Unknown command. Send /help for available commands."

    def handle_pending_input(self, chat_id, text):
        action = self.pending_action.pop(chat_id)
        action_map = {
            'add_keyword':    self.cmd_add_keyword,
            'remove_keyword': self.cmd_remove_keyword,
            'add_exclude':    self.cmd_add_exclude,
            'remove_exclude': self.cmd_remove_exclude,
        }
        handler = action_map.get(action)
        if handler:
            return handler(chat_id, text)
        return None

    # ── commands ─────────────────────────────────────────────────

    def cmd_start(self, chat_id):
        return (
            f"👋 *Welcome to K8s Job Monitor!*\n\n"
            f"I monitor Kubernetes jobs in `{self.namespace}`.\n\n"
            f"*Quick start:*\n"
            f"1. `/add_keyword your-job-name`\n"
            f"2. `/status` — see config & live pod counts\n"
            f"3. `/list_pods` — list matching pods\n\n"
            f"I'll notify you when jobs change status.\n"
            f"Send /help for all commands."
        )

    def cmd_status(self, chat_id):
        """显示配置 + 实时pod统计（不触发通知）"""
        user_config = self.users[chat_id]
        filters = user_config['filters']

        keywords = ", ".join(f"`{k}`" for k in filters['keywords']) if filters['keywords'] else "None"
        excludes = ", ".join(f"`{k}`" for k in filters['exclude_keywords']) if filters['exclude_keywords'] else "None"

        # 实时查询pods
        pods = self.get_filtered_pods_for_user(chat_id)

        status_counts = defaultdict(int)
        for pod in pods:
            status_counts[pod['phase']] += 1

        status_summary = ""
        if status_counts:
            status_summary = "\n\n*Live Pod Status:*\n"
            for phase in sorted(status_counts.keys()):
                emoji = self._get_status_emoji(phase)
                status_summary += f"{emoji} {phase}: {status_counts[phase]}\n"
        elif filters['keywords']:
            status_summary = "\n\nNo pods currently match your filters."

        return (
            f"📊 *Your Monitor Config*\n\n"
            f"Namespace: `{self.namespace}`\n"
            f"Include: {keywords}\n"
            f"Exclude: {excludes}\n"
            f"Matching pods: {len(pods)}"
            f"{status_summary}"
        )

    def cmd_add_keyword(self, chat_id, keyword):
        if not keyword:
            self.pending_action[chat_id] = 'add_keyword'
            return "📝 Send me the keyword to monitor:"

        keyword = keyword.strip()
        filters = self.users[chat_id]['filters']
        if keyword in filters['keywords']:
            return f"ℹ️ Keyword already exists: `{keyword}`"

        filters['keywords'].append(keyword)
        self.save_user_config(chat_id)
        return (
            f"✅ Added keyword: `{keyword}`\n"
            f"Your keywords: {', '.join(f'`{k}`' for k in filters['keywords'])}\n\n"
            f"Use /list\\_pods to see matching pods."
        )

    def cmd_remove_keyword(self, chat_id, keyword):
        filters = self.users[chat_id]['filters']
        if not keyword:
            self.pending_action[chat_id] = 'remove_keyword'
            if filters['keywords']:
                return (
                    f"📝 Which keyword to remove?\n"
                    f"Current: {', '.join(f'`{k}`' for k in filters['keywords'])}"
                )
            return "ℹ️ You have no keywords to remove."

        keyword = keyword.strip()
        if keyword in filters['keywords']:
            filters['keywords'].remove(keyword)
            self.save_user_config(chat_id)
            remaining = ', '.join(f'`{k}`' for k in filters['keywords']) if filters['keywords'] else "None"
            return f"✅ Removed keyword: `{keyword}`\nRemaining: {remaining}"
        return f"ℹ️ Keyword not found: `{keyword}`"

    def cmd_add_exclude(self, chat_id, keyword):
        if not keyword:
            self.pending_action[chat_id] = 'add_exclude'
            return "📝 Send me the keyword to exclude:"

        keyword = keyword.strip()
        filters = self.users[chat_id]['filters']
        if keyword in filters['exclude_keywords']:
            return f"ℹ️ Exclude keyword already exists: `{keyword}`"

        filters['exclude_keywords'].append(keyword)
        self.save_user_config(chat_id)
        return f"✅ Added exclude keyword: `{keyword}`"

    def cmd_remove_exclude(self, chat_id, keyword):
        filters = self.users[chat_id]['filters']
        if not keyword:
            self.pending_action[chat_id] = 'remove_exclude'
            if filters['exclude_keywords']:
                return (
                    f"📝 Which exclude to remove?\n"
                    f"Current: {', '.join(f'`{k}`' for k in filters['exclude_keywords'])}"
                )
            return "ℹ️ You have no exclude keywords to remove."

        keyword = keyword.strip()
        if keyword in filters['exclude_keywords']:
            filters['exclude_keywords'].remove(keyword)
            self.save_user_config(chat_id)
            return f"✅ Removed exclude keyword: `{keyword}`"
        return f"ℹ️ Exclude keyword not found: `{keyword}`"

    def cmd_clear_filters(self, chat_id):
        self.users[chat_id]['filters'] = {'keywords': [], 'exclude_keywords': []}
        self.users[chat_id]['job_states'] = {}
        self.save_user_config(chat_id)
        return "✅ All filters cleared and pod tracking reset."

    def cmd_list_pods(self, chat_id):
        """列出实时匹配的pods"""
        pods = self.get_filtered_pods_for_user(chat_id)

        if not pods:
            filters = self.users[chat_id]['filters']
            if not filters['keywords']:
                return "ℹ️ No keywords set. Add one with `/add_keyword`"
            return "ℹ️ No pods match your current filters."

        by_status = defaultdict(list)
        for pod in pods:
            by_status[pod['phase']].append(pod)

        message = f"📋 *Your Pods* ({len(pods)} total)\n\n"
        for phase in sorted(by_status.keys()):
            emoji = self._get_status_emoji(phase)
            pod_list = by_status[phase]
            message += f"{emoji} *{phase}* ({len(pod_list)})\n"
            for pod in pod_list[:5]:
                message += f"  • `{pod['job_name']}`\n"
            if len(pod_list) > 5:
                message += f"  _... and {len(pod_list) - 5} more_\n"
            message += "\n"

        return message

    def cmd_help(self):
        return (
            "🤖 *K8s Job Monitor Commands*\n\n"
            "*Setup:*\n"
            "`/add_keyword <word>` — monitor jobs containing this segment\n"
            "`/add_exclude <word>` — exclude jobs containing this segment\n\n"
            "*View:*\n"
            "`/status` — config + live pod counts\n"
            "`/list_pods` — list matching pods by status\n\n"
            "*Manage:*\n"
            "`/remove_keyword <word>` — remove keyword\n"
            "`/remove_exclude <word>` — remove exclude\n"
            "`/clear_filters` — clear everything\n\n"
            "*Note:* Keywords match by segment (split on `-`).\n"
            "E.g. `dd` matches `job-dd-rr-1` but not `added-thing`."
        )

    # ── background notification logic ────────────────────────────

    def check_and_notify_all_users(self):
        """定时任务：检查所有用户的pod变化并发送通知"""
        print(f"\n⏰ Checking pods at {datetime.now().strftime('%H:%M:%S')}")
        # 强制刷新缓存
        self._cache_time = 0

        for chat_id in list(self.users.keys()):
            try:
                self._detect_changes_and_notify(chat_id)
            except Exception as e:
                print(f"❌ Error for user {chat_id}: {e}")

    def _detect_changes_and_notify(self, chat_id):
        """检测单个用户的pod变化并发送通知（仅后台调用）"""
        user_config = self.users[chat_id]
        if not user_config['filters']['keywords']:
            return

        pods = self.get_filtered_pods_for_user(chat_id)
        current_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        job_states = user_config['job_states']
        current_pod_uids = set()
        changed = False

        for pod in pods:
            uid = pod['uid']
            current_pod_uids.add(uid)

            if uid not in job_states:
                # 新发现的pod，记录但不通知（避免首次添加关键词时大量通知）
                job_states[uid] = {
                    'phase': pod['phase'],
                    'name': pod['name'],
                    'job_name': pod['job_name'],
                    'first_seen': current_time,
                }
                changed = True
                print(f"  🆕 [{chat_id}] {pod['job_name']} — {pod['phase']}")
                continue

            prev = job_states[uid]
            if pod['phase'] != prev['phase']:
                emoji = self._get_status_emoji(pod['phase'])
                message = (
                    f"{emoji} *Pod Status Changed*\n\n"
                    f"Job: `{pod['job_name']}`\n"
                    f"`{prev['phase']}` → `{pod['phase']}`\n"
                    f"Time: {current_time}"
                )
                self.send_telegram_message(chat_id, message)

                prev['phase'] = pod['phase']
                prev['job_name'] = pod['job_name']
                changed = True
                print(f"  🔄 [{chat_id}] {pod['job_name']}: {prev['phase']} → {pod['phase']}")

        # 清理已消失的终态pods
        to_remove = [
            uid for uid in job_states
            if uid not in current_pod_uids
            and job_states[uid]['phase'] in ('Succeeded', 'Failed', 'Unknown')
        ]
        for uid in to_remove:
            del job_states[uid]
            changed = True

        if changed:
            self.save_user_config(chat_id)

    # ── helpers ──────────────────────────────────────────────────

    @staticmethod
    def _get_status_emoji(phase):
        p = phase.lower()
        if 'succeeded' in p or 'complete' in p:
            return "✅"
        if 'failed' in p or 'error' in p:
            return "❌"
        if 'running' in p:
            return "▶️"
        if 'pending' in p:
            return "⏳"
        if 'unknown' in p:
            return "❓"
        return "ℹ️"

    # ── main loop ────────────────────────────────────────────────

    def run(self, check_interval=180):
        print("=" * 60)
        print("🚀 Multi-User Kubernetes Monitor")
        print("=" * 60)
        print(f"📍 Namespace: {self.namespace}")
        print(f"⏱️  Check interval: {check_interval}s ({check_interval / 60:.0f} min)")
        print(f"👥 Users: {len(self.users)}")
        print(f"🔑 Keyword matching: segment-based (split on '-')")
        print("=" * 60)

        last_check = 0

        # 初始扫描
        self.check_and_notify_all_users()
        last_check = time.time()

        while True:
            try:
                self.check_telegram_messages()

                now = time.time()
                if now - last_check >= check_interval:
                    self.check_and_notify_all_users()
                    last_check = now

                time.sleep(2)

            except KeyboardInterrupt:
                print("\n⏹️  Stopped.")
                break
            except Exception as e:
                print(f"❌ Loop error: {e}")
                time.sleep(60)


def main():
    TELEGRAM_BOT_TOKEN = "8522199993:AAHi89KjHMvvJ_XTJrphd0H8H2xs-6iANgY"
    NAMESPACE = "cogrob"
    NAMESPACE = os.environ.get("K8S_NAMESPACE", "cogrob")

    monitor = MultiUserKubernetesMonitor(
        telegram_bot_token=TELEGRAM_BOT_TOKEN,
        namespace=NAMESPACE,
    )
    monitor.run(check_interval=180)


if __name__ == "__main__":
    main()