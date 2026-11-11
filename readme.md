# PWS400K – automatická instalace Armbianu a Klipperu

Repozitář obsahuje skripty pro bezobslužnou instalaci softwarového prostředí
tiskárny PWS400K na Orange Pi 3 LTS s Armbianem. Při prvním startu Armbianu
se nakonfiguruje uživatel a síť, spustí se provisioning a následně se
nainstalují a nastaví Klipper, Moonraker a webové rozhraní Mainsail.

## Soubory

- `.not_logged_in_yet` – přednastavení prvního spuštění Armbianu: vytvoří
  uživatele `pi`, nastaví jazyk, časové pásmo a výchozí síť.
- `provisioning.sh` – skript prvního spuštění, který nastaví název zařízení,
  připraví systém a UART3 a spustí instalační skript uživatele `pi`.
- `pws400k-setup.sh` – vlastní instalace Klipperu, Moonrakeru, Mainsailu,
  Crowsnestu, pluginu Klipper_IP a konfigurace PWS400K.

## Příprava instalačního média

Po zapsání Armbianu na kartu připojte její linuxový (ext4) kořenový oddíl
na počítači. Soubory `.not_logged_in_yet` a `provisioning.sh` zkopírujte do složky
`/root/` v kořenovém systému instalace Armbianu – tedy do složky `root`
na připojeném oddílu, nikoli do kořene samotného oddílu:

```text
/root/.not_logged_in_yet
/root/provisioning.sh
```

Soubor `pws400k-setup.sh` můžete do `/root/` zkopírovat také, není to však
nutné: pokud tam při prvním spuštění nebude, `provisioning.sh` jej stáhne
z tohoto GitHub repozitáře. Například pokud je oddíl připojený jako `/mnt`,
cílové cesty jsou `/mnt/root/.not_logged_in_yet` a
`/mnt/root/provisioning.sh` (případně také `/mnt/root/pws400k-setup.sh`).
Poté oddíl bezpečně odpojte a kartu vložte do Orange Pi 3 LTS.

Armbian použije `.not_logged_in_yet` při prvním spuštění a automaticky zavolá
`/root/provisioning.sh`. Ten najde lokálně připravený
`/root/pws400k-setup.sh` (nebo jej stáhne, pokud jej tam nenajde), zkopíruje
jej do domovské složky uživatele `pi` a spustí instalaci. Po dokončení se
zařízení restartuje.

## Nastavení instalace

Před prvním spuštěním upravte podle potřeby:

- Hesla uživatele `root` a `pi` a síťové údaje v `.not_logged_in_yet`.
  Soubor obsahuje výchozí hesla, která je nutné před nasazením změnit.
- `LANG_VARIANT`, `PRINTER_HOSTNAME`, `PRINTER_SERIAL` a
  `ENABLE_SPECTODA` v `provisioning.sh`. Jazyk konfigurace je `en` nebo `cz`;
  Spectoda je ve výchozím stavu vypnutá.
- Wi-Fi je ve výchozím stavu vypnutá a síť používá DHCP. Pro jiné síťové
  nastavení upravte příslušné hodnoty v `.not_logged_in_yet`.

Instalační skripty stahují další veřejné repozitáře a balíčky, proto zařízení
potřebuje při instalaci funkční připojení k internetu. Cílová konfigurace
skriptů předpokládá Orange Pi 3 LTS, uživatele `pi` a komunikaci s řídicí
deskou tiskárny přes UART3.

Po instalaci je Mainsail dostupný na `http://<IP-adresa-tiskárny>/`.
Instalační skript vypíše také adresy Moonraker API a streamu kamery.

## Protokoly a opětovné spuštění

Protokol prvního spuštění se ukládá do
`/var/log/pws400k-provisioning.log`; podrobnosti instalačního skriptu do
`/tmp/pws400k-setup.log`. Úspěšné dokončení prvního provisioning běhu označuje
`/root/.provisioning_done`, takže následné spuštění `provisioning.sh` skončí
bez opakování instalace.