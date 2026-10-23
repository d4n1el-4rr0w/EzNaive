
# EzNaive — Пошаговый гайд по установке

**Сервер:** Ubuntu (22.04 и выше) или Debian (11 и выше)

**Системные требования:**
- 1 vCPU
- 1 GB RAM
- 10 GB места

 **Что нужно заранее:**
- VPS с Ubuntu/Debian
- Поддомен / домен, который указывает на IP сервера
- Клиент вроде V2RayN, NekoBox, Karing или аналогичный

---

## Обновление системы и установка базы


```bash
apt update && apt upgrade -y

apt install -y curl wget git openssl ufw
```

---

## Автоматический способ настройки сервера:

Cкрипт установки в одну команду. Рекомендуется ознакомиться с его содержимым перед выполнением.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/d4n1el-4rr0w/EzNaive/refs/heads/main/naive.sh)
```

Просмотреть зарегистрированных пользователей после выполнения скрипта:

```bash
cat /root/naiveproxy-users.txt
```

---
