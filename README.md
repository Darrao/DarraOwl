# DarraOwl

Garde ton MacBook éveillé, capot fermé compris, pendant une durée limitée.
Chaque session a une heure de fin. À cette heure-là, la veille revient, même si
l'app a planté ou a été quittée.

Il y a deux apps :

- **Mac** : une app de la barre des menus. Elle garde le Mac éveillé et éteint
  l'écran, coupe le son, met en pause les apps bruyantes quand le capot est
  fermé.
- **iPhone** : elle affiche l'état du Mac et le pilote d'où tu veux. Elle
  propose aussi des notifications, une Live Activity dans la Dynamic Island,
  des widgets et Siri.

Sans serveur : l'iPhone joint le Mac en direct (réseau local, Tailscale) ou par
ta base iCloud privée.

> Pose le Mac sur une surface stable et ventilée, jamais dans un sac fermé.

## Installation

**Pour l'utiliser :** télécharge l'app Mac dans les
[Releases](https://github.com/Darrao/DarraOwl/releases), glisse-la dans
Applications et ouvre-la. Installe ensuite l'app iPhone depuis l'App Store ou
TestFlight.

**Depuis le code source :**

Il faut macOS 26 ou plus récent sur un Mac Apple Silicon, ainsi que Xcode et
XcodeGen.

```bash
scripts/install-mac.sh
```

Le script refuse de continuer si Insomnia est encore installé. Il construit
l'app, la copie dans `/Applications` et l'ouvre. Il n'utilise jamais `sudo`.

## Premier lancement

1. Clique sur la chouette dans la barre des menus, puis sur **Installer le
   composant système**.
2. Réglages Système s'ouvre sur **Général > Ouverture**. Sous **Autoriser en
   arrière-plan**, active **DarraOwl**. macOS demande ton mot de passe ou
   Touch ID.
3. Reviens au menu : il propose maintenant les durées.

Le composant système est un petit service qui tourne en root. C'est le seul
à modifier les réglages d'alimentation. Il n'accepte que l'app DarraOwl
signée par le même développeur. Il tient le journal des changements et
rétablit la veille à l'heure de fin, au démarrage du Mac, et quand on le
désactive.

DarraOwl s'ajoute aussi à l'ouverture de session. Tu peux retirer ce réglage
dans DarraOwl > Réglages.

## Utilisation

- **Démarrer** : clique sur 30 min, 1 h, 2 h (Entrée) ou 4 h, ou tape une
  durée libre (`90`, `1h30`, `2:15`).
- **Prolonger** : clique sur +30 min ou +1 h pendant la session. La fin
  ne dépasse jamais la durée maximale (12 h par défaut, 24 h au plus).
- **Arrêter** : maintiens le bouton enfoncé 1,5 s.
- **Quitter** l'app arrête aussi la session.

Pendant une session, sur batterie :

- sous 40 %, le mode économie d'énergie s'active, puis se désactive au
  retour du chargeur ;
- sous 15 %, ou si la batterie devient illisible, la session s'arrête.

Une température critique arrête la session, une température élevée active le
mode économie d'énergie. Le composant système applique ces règles même quand
l'app est fermée. Tu peux changer les seuils dans Réglages.

## Capot fermé

Pendant une session, fermer le capot :

- éteint l'écran et le rétroéclairage du clavier ;
- coupe le son ;
- active le mode économie d'énergie ;
- met en pause Slack, WhatsApp et Discord ;
- met en pause Docker Desktop, si deux vérifications de suite ne trouvent
  aucun conteneur en marche.

Tout est rétabli à l'ouverture du capot. Si la session se termine capot
fermé, ou après un plantage, la restauration a lieu au retour. Les apps
d'appel, de visio, d'enregistrement et de dictée (Teams, Zoom, Webex,
FaceTime, etc.) ne sont jamais mises en pause. Tu peux changer chacun de ces
réglages dans DarraOwl > Réglages > Capot fermé.

Comment ça marche :

- Chaque valeur (luminosité, volume, liste des process mis en pause) est
  écrite dans le journal du composant système avant d'être modifiée.
- La mise en pause envoie `SIGSTOP` à l'app et à tous ses process enfants. La
  reprise envoie `SIGCONT`, seulement aux process dont l'identité (pid, heure
  de démarrage, démarrage du Mac) n'a pas changé.
- Le composant système relance lui-même les apps en pause à la fin de la
  session, même sans l'app.
- La luminosité et le son ne peuvent être rétablis que par l'app. Elle le
  fait à son prochain lancement si besoin.
- Une sortie audio débranchée garde son réglage, rétabli quand elle
  revient. Le menu propose aussi **Oublier**.
- Pour l'écran et le clavier, DarraOwl utilise des API privées de macOS. Le
  moyen public (`pmset displaysleepnow`) ne tient pas : fermer le capot
  rallume l'écran. Ces API ne sont appelées que sur macOS 26, la version sur
  laquelle elles ont été mesurées. Sur une autre version, l'écran et le
  clavier sont laissés tels quels, et les Réglages l'indiquent.

## Toujours actif (mode présence)

C'est le même principe que Caffeine ou Amphetamine. Choisis **Sans limite**,
1 h, 2 h, 4 h ou 8 h dans la section **Toujours actif**. Tant que le capot
est ouvert :

- le Mac ne se met pas en veille et l'écran reste allumé ;
- une activité est déclarée chaque minute, pour que Teams te garde
  « Disponible ».

**Sans limite** reste actif après un redémarrage, jusqu'à ce que tu cliques
sur **Arrêter**. Sur batterie, le mode s'arrête sous le seuil de fin de
session (15 %), ou en cas de température critique.

Ce mode ne change aucun réglage système. Il utilise des assertions
d'alimentation que macOS retire dès que l'app se ferme, même en cas de
plantage. Il ne garde pas le Mac éveillé capot fermé : pour ça, lance une
session, qui a toujours une heure de fin.

## iPhone

- **Appairage** : DarraOwl > **iPhone…** > **Afficher le code d'appairage**,
  puis scanne le code avec l'app iPhone. Le code est valable 5 minutes et ne
  sert qu'une fois. Les clés restent dans le trousseau de chaque appareil.
- **Ce que l'iPhone affiche** : en ligne, en veille ou « vu pour la dernière
  fois à… », la session et le temps restant, la batterie et l'autonomie, la
  température, le capot, le réseau et la data de la session, les agents de
  code en cours, les conteneurs Docker.
- **Ce que l'iPhone peut faire** : démarrer, prolonger ou arrêter une session,
  mettre le Mac en veille, gérer Docker, changer les réglages capot fermé, les
  alertes et les seuils de batterie. Mettre en veille et arrêter un conteneur
  demandent Face ID.
- **Notifications**, avec les boutons +1 h et Arrêter : session bientôt finie,
  batterie qui ne tiendra pas, Mac qui chauffe, capot ouvert ou chargeur
  débranché, réseau revenu après une coupure, data au-delà du seuil, récap de
  fin de session.
- **Live Activity** sur l'écran verrouillé et dans la Dynamic Island : temps
  restant, batterie, agents, avec les boutons +1 h et Arrêter. Faute de serveur
  de push, elle démarre quand tu ouvres l'app pendant une session, ou quand tu
  lances la session depuis l'iPhone.
- **Widgets** pour l'écran d'accueil et l'écran verrouillé.
- **Siri** : « Prolonge le Mac d'une heure avec DarraOwl », « Arrête la session
  du Mac avec DarraOwl », « État du Mac avec DarraOwl ».
- **Connexion** : chiffrée en TLS, avec une clé par iPhone appairé. Sur le même
  Wi-Fi, sur le partage de connexion de l'iPhone ou via Tailscale, elle est
  directe. Sinon, elle passe par ta base iCloud privée. Chaque commande est
  signée, expire au bout de 60 s et ne s'exécute qu'une fois.
- **Désappairer**, depuis le Mac, coupe l'accès de l'iPhone immédiatement.

## Claude Code

DarraOwl > Réglages > Claude Code > **Copier la configuration**, puis colle-la
dans `~/.claude/settings.json`, en la fusionnant avec ta clé `hooks` si tu en
as déjà une. Tu reçois alors « Claude a fini » ou « Claude attend ta
validation », avec le nom du projet, quand personne n'est devant le Mac
(capot fermé ou une minute sans activité).

Le Mac n'écoute que sur `127.0.0.1:52526` et exige un jeton, rangé dans le
trousseau. Seuls l'événement et le nom du dossier sont lus, jamais le contenu.

Les agents en cours (claude, codex, gemini) sont détectés automatiquement,
avec leur projet. Les noms de projets peuvent être masqués dans les réglages.

## Ce que DarraOwl modifie

| Réglage | Pendant la session | Retour |
|---|---|---|
| `pmset -a disablesleep` | 1 | la valeur d'avant |
| `pmset -b/-c lowpowermode` | 1, seulement sous le seuil de batterie ou en cas de chaleur | la valeur d'avant, pour chaque profil |

Chaque changement est écrit dans
`/Library/Application Support/DarraOwl/journal.json` avant d'être appliqué.
Une restauration qui échoue reste dans le journal et est retentée toutes les
10 s. Le menu l'affiche.

Journal du composant système :

```bash
/usr/bin/log show --last 1h --predicate 'subsystem == "com.darrao.darraowl"'
```

## Mise à jour

Relance `scripts/install-mac.sh`. Le script refuse de continuer pendant
une session : arrête-la d'abord. Une fois l'app remplacée, le composant
système redémarre seul sur la nouvelle version dès qu'il n'a plus rien en
cours. Cela prend au plus 30 s.

## Dépannage

- **Le menu affiche « Composant système en attente de ton autorisation »** :
  ouvre Réglages Système > Général > Ouverture, puis active DarraOwl sous
  **Autoriser en arrière-plan**.
- **Le menu affiche « Le composant système ne répond pas encore »** : dans ce
  même réglage, désactive puis réactive DarraOwl. Le composant système
  rétablit tout avant de s'arrêter, puis redémarre.
- **Journal** : `/usr/bin/log show --last 1h --predicate 'subsystem ==
  "com.darrao.darraowl"'`. Dans zsh, `log` seul désigne une commande interne :
  il faut écrire le chemin complet.

## Désinstallation

```bash
scripts/uninstall.sh          # session arrêtée, réglages rétablis, app supprimée
scripts/uninstall.sh --purge  # supprime aussi les préférences
```

La désinstallation supprime aussi les clés d'appairage et les données
iCloud de DarraOwl. Le script ne lance jamais `sudo`. Si la veille n'a pas pu être rétablie, il
affiche la commande exacte à lancer.

## Développement

```bash
swift test --package-path shared
swift test --package-path mac
scripts/build-mac.sh Debug
```

Les tests utilisent des faux : ils ne lancent jamais `pmset`, iCloud ni le
réseau.

## Licence

[MIT](LICENSE). Des parties sont adaptées d'Insomnia (MIT), voir [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
