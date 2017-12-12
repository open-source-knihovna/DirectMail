![logo KohaCZ](https://github.com/open-source-knihovna/SmartWithdrawals/blob/master/SmartWithdrawals/koha_cz.png "Logo Česká komunita Koha")
![logo R-Bit Technology, s.r.o.](https://github.com/open-source-knihovna/SmartWithdrawals/blob/master/SmartWithdrawals/logo.png "Logo R-Bit Technology, s.r.o.")
![logo MK ČR](https://github.com/open-source-knihovna/SmartWithdrawals/blob/master/SmartWithdrawals/logo_mkcr.png "Logo MK ČR")

Plugin vytvořila společnost R-Bit Technology, s. r. o. ve spolupráci s českou komunitou Koha, za finančního přispění Ministerstva kultury České republiky.

# Úvod

Zásuvný modul 'Přímé oslovování čtenářů' byl vytvořen jako nástroj pro hromadné rozesílání zpráv vybraným skupinám čtenářů. Využitím tohoto nástroje si knihovny mohou vyhledávat nejvhodnější adresáty podle souboru stanovených parametrů. Výběr není subjektivní či pocitový, ale je založen na reálných datech o čtenářích a jejich způsobu využívání knihovních služeb.

Pro skutečně snadnou práci lze nastavení vyhledávacích parametrů uložit, pojmenovat a celou předvolbu případně doplnit i delším slovním popisem. Uložené předvolby se dají snadno duplikovat a vytvářet tak velmi rychle různé varianty nastavení. Z důvodu vyšší ochrany osobních údajů nejsou údaje o konkrétních čtenářích nikde zobrazeny. Výsledek je vždy zobrazen pouze jako celkový počet nalezených adresátů s možností odeslat jim zvolenou zprávu.

# Instalace

## Zprovoznění Zásuvných modulů

Institut zásuvných modulů umožňuje rozšiřovat vlastnosti knihovního systému Koha dle specifických požadavků konkrétní knihovny. Zásuvný modul se instaluje prostřednictvím balíčku KPZ (Koha Plugin Zip), který obsahuje všechny potřebné soubory pro správné fungování modulu.

Pro využití zásuvných modulů je nutné, aby správce systému tuto možnost povolil v nastavení.

Nejprve je zapotřebí provést několik změn ve vaší instalaci Kohy:

* V souboru koha-conf.xml změňte `<enable_plugins>0</enable_plugins>` na `<enable_plugins>1</enable_plugins>`
* Ověřte, že cesta k souborům ve složce `<pluginsdir>` existuje, je správná a že do této složky může webserver zapisovat
* Pokud je hodnota `<pluginsdir>` např. `/var/lib/koha/kohadev/plugins`, vložte následující kód do konfigurace webserveru:
```
Alias /plugin/ "/var/lib/koha/kohadev/plugins/"
<Directory "/var/lib/koha/kohadev/plugins">
  Options +Indexes +FollowSymLinks
  AllowOverride All
  Require all granted
</Directory>
```
* Načtěte aktuální konfiguraci webserveru příkazem `sudo service apache2 reload`

Jakmile je nastavení připraveno, budete potřebovat změnit systémovou konfigurační hodnotu UseKohaPlugins v administraci Kohy. Na stránce Nástroje pak najdete odkaz Zásuvné moduly. Aktuální verzi pluginu [stahujte v sekci Releases](https://github.com/open-source-knihovna/DirectMail/releases).

## Nastavení specifické pro modul



Více informací, jak s nástrojem pracovat naleznete na [wiki](https://github.com/open-source-knihovna/DirectMail/wiki)
