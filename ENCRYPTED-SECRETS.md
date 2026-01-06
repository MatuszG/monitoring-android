# Encrypted Secrets Management

System zarządzania wrażliwymi danymi (tokeny, hasła) z szyfrowaniem AES-256.

## Przegląd

Zamiast przechowywać tokeny i hasła jako plain text w `config.env`, używamy szyfrowanego pliku:
- **Lokalizacja**: `~/.secrets/config.enc` (w home directory)
- **Szyfowanie**: AES-256-CBC (openssl)
- **Weryfikacja**: SHA256 hash głównego hasła
- **Dostęp**: Wymaga hasła przy każdym starcie

## Obsługiwane Sekrety

```bash
TELEGRAM_BOT_TOKEN       # Token bota Telegram
TELEGRAM_CHAT_ID         # ID czatu dla powiadomień
RCLONE_PASSWORD          # Hasło rclone
RCLONE_API_KEY           # API key rclone
GIT_PAT_TOKEN            # GitHub Personal Access Token
```

## Komendy

### Inicjalizacja systemu

```bash
./workflow.sh secrets-init
```

**Co się dzieje:**
1. Tworzy katalog `~/.secrets/` (uprawnienia 700)
2. Prosi o **główne hasło** (min 12 znaków)
3. Weryfikuje hasło (pytanie powtórne)
4. Tworzy szyfrowany plik z domyślnymi sekretami
5. Zapisuje SHA256 hash hasła dla weryfikacji

**Ważne**: 
- ⚠️ Zapamiętaj główne hasło! Bez niego nie będziesz mieć dostępu do sekretów
- Plik `.hash` zawiera tylko hash hasła, a nie samo hasło
- Pierwszy raz przy `./workflow.sh setup` automatycznie wywoła `init_secrets`

---

### Edycja sekretów

```bash
./workflow.sh secrets-edit
```

**Co się dzieje:**
1. Prosi o główne hasło
2. Weryfikuje hasło (porównanie SHA256)
3. Odszyfrowuje plik do temp pliku
4. Otwiera edytor (nano/vim - zmienna EDITOR)
5. Po zamknięciu edytora - reszyfruje i zapisuje

**Przykład edycji:**
```bash
./workflow.sh secrets-edit
# Wprowadź hasło
# Edytor otwiera plik:
# ---
# TELEGRAM_BOT_TOKEN="7714242462:AAGFumjg..."
# TELEGRAM_CHAT_ID="-4994390383"
# RCLONE_PASSWORD="moje-haslo"
# ---
# Po zapisaniu - automatycznie reszyfruje
```

---

### Ładowanie sekretów w skryptach

```bash
./workflow.sh secrets-load
```

**Co się dzieje:**
1. Prosi o główne hasło
2. Odszyfrowuje sekrety
3. Załadowuje do zmiennych środowiskowych
4. Te zmienne dostępne w bieżącej sesji

**Użycie w skryptach:**
```bash
source ~/.secrets/decrypted.env  # Po wcześniejszym ładowaniu
echo "$TELEGRAM_BOT_TOKEN"       # Zmienna dostępna
```

---

## Automatyczne Ładowanie

### Na starcie Workflow

Gdy uruchomisz:
```bash
./workflow.sh start
```

System automatycznie:
1. Sprawdza czy plik sekretów istnieje (`~/.secrets/config.enc`)
2. Prosi o główne hasło
3. Weryfikuje hasło
4. Odszyfrowuje i ładuje sekrety
5. Uruchamia workflow z dostępnymi zmiennymi

### W Telegram Notifications

Funkcja `send_telegram()` automatycznie:
1. Sprawdza czy istnieje szyfrowany plik
2. Jeśli $MASTER_PASSWORD jest ustawiona - używa jej
3. Jeśli nie - fallback na `config.env`
4. Wysyła powiadomienie

---

## Architektura Bezpieczeństwa

### Zmienne Środowiskowe

```bash
# NIGDY w ~/.bashrc lub config.env
TELEGRAM_BOT_TOKEN="xxx"

# ZAMIAST TEGO: w ~/.secrets/config.enc (zaszyfrowany)
# Odszyfrowany tylko w pamięci RAM podczas sesji
```

### Uprawnienia Plików

```bash
~/.secrets/              # 700 (rwx------)  - Tylko właściciel
~/.secrets/config.enc    # 600 (rw-------)  - Tylko właściciel
~/.secrets/.hash         # 600 (rw-------)  - Tylko właściciel
```

### Proces Szyfrowania

```
1. Wpisz hasło (12+ znaków)
   ↓
2. openssl: Wylicz SHA256 hash hasła
   ↓
3. openssl: Szyfruj plik sekretów (AES-256-CBC + salt)
   ↓
4. Zapisz SHA256 w ~/.secrets/.hash
   ↓
5. Plik już zaszyfrowany, gotowy do użytku
```

### Proces Odszyfrowywania

```
1. Wpisz hasło
   ↓
2. Wylicz SHA256 hasła
   ↓
3. Porównaj z ~/.secrets/.hash
   ↓
4. Jeśli zgadza się - odszyfruj
   ↓
5. Załaduj zmienne do RAM
```

---

## Przypadki Użycia

### Scenariusz 1: Nowa Instalacja

```bash
# 1. Pierwsza konfiguracja
./workflow.sh setup
# → System pyta o główne hasło
# → Tworzy ~/.secrets/config.enc

# 2. Uruchamianie workflow
./workflow.sh start
# → Prosi o główne hasło
# → Ładuje sekrety
# → Uruchamia workflow
```

### Scenariusz 2: Zmiana Tokenu Telegram

```bash
./workflow.sh secrets-edit
# → Wpisz hasło
# → Edytor: zmień TELEGRAM_BOT_TOKEN
# → Zapisz (Ctrl+X, Y, Enter)
# → Reszyfruje automatycznie
```

### Scenariusz 3: Dostęp z Update Script

```bash
# W update.sh:
if [ -f "$SECRETS_FILE" ]; then
    # Odszyfruj i załaduj
    eval "$(openssl enc -aes-256-cbc -d -in "$SECRETS_FILE" \
        -k "$MASTER_PASSWORD" 2>/dev/null)"
fi

# Teraz dostępne:
echo "$TELEGRAM_BOT_TOKEN"
```

---

## Troubleshooting

### ❌ "Błędne hasło!"

```bash
# Wpisałeś złe hasło
# Spróbuj jeszcze raz:
./workflow.sh secrets-edit
```

### ❌ "Plik sekretów nie istnieje"

```bash
# Inicjalizuj pierwszy raz:
./workflow.sh secrets-init
```

### ❌ Zapomniałem hasła

⚠️ **PROBLEM**: Bez hasła nie możesz uzyskać dostępu do sekretów.

**Rozwiązanie**:
```bash
# 1. Usuń stary plik
rm -rf ~/.secrets/

# 2. Zainicjalizuj na nowo (z nowym hasłem)
./workflow.sh secrets-init

# 3. Zaenter dane znowu
./workflow.sh secrets-edit
```

### ❌ Telegram nie wysyła

```bash
# Sprawdź czy sekrety są załadowane:
./workflow.sh secrets-load

# Test powiadomienia:
./workflow.sh telegram-test
```

---

## Workflow Integracji

```bash
# config.env (plain text - NON-SENSITIVE)
RCLONE_REMOTE="gdrive"
RCLONE_ROOT=""
INCOMING_DIR="/mnt/incoming"
SORTED_DIR="/mnt/sorted"
GDRIVE_PATH="Posortowane"

# ~/.secrets/config.enc (encrypted)
TELEGRAM_BOT_TOKEN="7714242462:AAGFumjg..."
TELEGRAM_CHAT_ID="-4994390383"
RCLONE_PASSWORD="***encrypted***"
GIT_PAT_TOKEN="ghp_***encrypted***"
```

---

## Hasło Główne - Best Practices

✅ **DOBRZE:**
- `MyP@ssw0rd!Secure2024` (12+ znaków, mieszane)
- `Workflow_Secrets_2024_ABC` (długie, pamiętalne)
- `TermuxAuto123!@#` (specjalne znaki)

❌ **ŹLE:**
- `password` (za krótkie)
- `12345678` (tylko cyfry)
- `workflow` (słownikowe słowo)
- Wpisywanie w terminal (history!)

💡 **HINT**: Jeśli nie chcesz wpisywać hasła każdy raz, możesz ustawić zmienną:
```bash
export MASTER_PASSWORD="twoje-haslo"
./workflow.sh start
```

⚠️ Ale pamiętaj: to zmniejsza bezpieczeństwo!

---

## Podsumowanie

| Funkcja | Komenda | Skutek |
|---------|---------|--------|
| Inicjalizacja | `./workflow.sh secrets-init` | Tworzy ~/.secrets/config.enc |
| Edycja | `./workflow.sh secrets-edit` | Zmienia hasła/tokeny |
| Ładowanie | `./workflow.sh secrets-load` | Załadowuje do zmiennych |
| Automatycznie | `./workflow.sh start` | Ładuje sekrety na starcie |
| Telegram | `send_telegram()` | Używa załadowanych sekretów |

---

## Pliki

```
~/.secrets/
├── config.enc          # Szyfrowany plik z sekretami (AES-256)
└── .hash              # SHA256 hash hasła (weryfikacja)

./
├── config.env         # Plain text config (non-sensitive)
├── workflow.sh        # Main script + funkcje szyfrowania
└── update.sh          # Auto-update (może używać sekretów)
```
