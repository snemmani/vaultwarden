# Vaultwarden backup & restore

Backups: `scripts/backup_vaultwarden_r2.sh`, cron at :15 and :45 every hour.
Config: `~/.config/vaultwarden/r2-backup.env`. Log: `backup-work/backup.log`.
Destination: R2 `r2:jarvis/vaultwarden/vaultwarden-<UTC timestamp>.tar.gz.gpg`, kept 30 days.
Each archive contains `db.sqlite3` (consistent snapshot), `rsa_key.pem`,
`attachments/`, `sends/` (if present) and `docker-compose.yml`.

## What you need OFF this laptop (store on paper / a second device — NOT only in Vaultwarden)

1. GPG passphrase (contents of `~/.config/jarvis/backup-passphrase.txt`)
2. Cloudflare R2 access key + secret, and the account endpoint
   (or just your Cloudflare login, to download from the dashboard)
3. Your Vaultwarden master password (and 2FA recovery code if 2FA is on)

## Restore on a new machine

```bash
# 1. Get the latest archive (or download it from the Cloudflare R2 dashboard)
rclone config                       # recreate remote "r2": type s3, provider Cloudflare
rclone ls r2:jarvis/vaultwarden | sort -k2 | tail -1
rclone copy r2:jarvis/vaultwarden/<file>.tar.gz.gpg .

# 2. Decrypt and unpack
gpg -d <file>.tar.gz.gpg | tar -xzf -     # prompts for the passphrase

# 3. Run it
mkdir -p ~/vaultwarden && cd ~/vaultwarden
mv /path/to/vaultwarden ./vw-data
mv vw-data/docker-compose.yml .
docker compose up -d                       # then log in with your master password
```

Emergency read-only access without a server: point any Bitwarden client at
`http://127.0.0.1:8000` after step 3, or temporarily run step 3 on any machine with Docker.
