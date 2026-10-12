# DarraOwl

Garde ton MacBook éveillé, capot fermé compris, pendant une durée limitée ou
tant qu'un agent de code tourne. Chaque session a une heure de fin. À cette heure-là, la veille revient, même si
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
  durée libre en jours, heures et minutes.
- **Prolonger** : clique sur +30 min ou +1 h pendant la session. La fin
  ne dépasse jamais la durée maximale (12 h par défaut, 24 h au plus).
- **Arrêter** : maintiens le bouton enfoncé 1,5 s.
- **Quitter** l'app arrête aussi la session et remet le son et la luminosité.

Pendant une session, sur batterie :

- sous 40 %, le mode économie d'énergie s'active (sur les Mac qui le
  proposent), puis se désactive au retour du chargeur ;
- sous 15 %, ou si la batterie devient illisible, la session s'arrête.

Une température critique arrête la session, une température élevée active le
mode économie d'énergie. Le composant système applique ces règles même quand
l'app est fermée. Tu peux changer les seuils dans Réglages.

## Capot fermé

Pendant une session, fermer le capot :

- éteint l'écran et le rétroéclairage du clavier ;
- coupe le son ;
- active le mode économie d'énergie, sur les Mac qui le proposent ;
- met en pause Slack, WhatsApp et Discord ;
- met en pause Docker Desktop, si deux vérifications de suite ne trouvent
  aucun conteneur en marche.

Tout est rétabli à l'ouverture du capot. Si la session se termine capot
fermé, la restauration a lieu au retour. Les apps d'appel, de visio,
d'enregistrement et de dictée (Teams, Zoom, Webex, FaceTime, etc.) ne sont
jamais mises en pause. Tu peux changer chacun de ces réglages dans DarraOwl >
Réglages > Capot fermé.

L'écran, le son et les apps sont gérés par l'app DarraOwl : elle doit être
ouverte (elle démarre avec ta session). Une session lancée depuis le Terminal
juste avant de fermer le capot est prise en compte dès que l'app la voit.

Comment ça marche :

- Chaque valeur (luminosité, volume, liste des process mis en pause) est
  écrite dans le journal du composant système avant d'être modifiée.
- La mise en pause envoie `SIGSTOP` à l'app et à tous ses process enfants. La
  reprise envoie `SIGCONT`, seulement aux process dont l'identité (pid, heure
  de démarrage, démarrage du Mac) n'a pas changé.
- Le composant système relance lui-même les apps en pause à la fin de la
  session, même sans l'app.
- Le composant système relance aussi les apps en pause à l'ouverture du
  capot, même si l'app a planté entre-temps.
- La luminosité et le son ne peuvent être rétablis que par l'app. Après un
  plantage, elle le fait à son prochain lancement.
- Une sortie audio débranchée garde son réglage, rétabli quand elle
  revient. Le menu propose aussi **Oublier**.
- Pour l'écran et le clavier, DarraOwl utilise des API privées de macOS. Le
  moyen public (`pmset displaysleepnow`) ne tient pas : fermer le capot
  rallume l'écran. Ces API ne sont appelées que sur macOS 26 et 27, les
  versions sur lesquelles elles ont été mesurées. Sur une autre version,
  l'écran et le clavier sont laissés tels quels, et les Réglages l'indiquent.

Deux cas où DarraOwl en fait moins à la fermeture du capot :

- **un écran externe est branché** : le Mac est sur un bureau, tu travailles
  dessus. Rien n'est éteint, coupé ni mis en pause, et le mode économie
  d'énergie n'est pas activé. Brancher l'écran capot fermé rétablit tout ; le
  débrancher (le Mac part dans un sac) applique les actions du capot fermé ;
- **un appel est en cours** (un micro est utilisé) : le son n'est pas coupé
  et aucune app n'est mise en pause, pour ne pas couper l'appel. L'écran
  s'éteint quand même.

Une app dans laquelle tourne un agent (Terminal, iTerm, VS Code…) n'est
jamais mise en pause, même si elle est dans la liste.

## Toujours actif (mode présence)

C'est le même principe que Caffeine ou Amphetamine. Choisis **Sans limite**,
1 h, 2 h, 4 h ou 8 h dans la section **Toujours actif**. Tant que le capot
est ouvert :

- le Mac ne se met pas en veille et l'écran reste allumé ;
- une activité est déclarée chaque minute, pour que Teams te garde
  « Disponible ».

**Éteindre l'écran** depuis l'iPhone le laisse éteint : le Mac reste éveillé,
mais ton statut peut passer en absent tant que personne n'y touche.

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
  suivre un agent, mettre le Mac en veille, gérer Docker, changer les réglages
  capot fermé, les alertes et les seuils de batterie.
- **Contrôles** : « Toujours actif » (sans limite ou 1 à 8 h), éteindre
  l'écran, verrouiller le Mac, couper ou remettre le son, mettre en pause ou
  relancer Slack, WhatsApp et Discord (pendant une session), arrêter un agent
  (un Ctrl-C, puis l'arrêt s'il tourne encore 3 s après). Pendant une session, le son coupé à distance est noté
  dans le journal et rétabli à la fin.
- **Face ID** est demandé pour mettre en veille, arrêter un conteneur et
  arrêter un agent.
- **Notifications**, avec les boutons « Prolonger d'1 h » (qui relance une
  heure si la session est déjà finie) et « Arrêter la session » : session bientôt finie,
  batterie qui ne tiendra pas, Mac qui chauffe, capot ouvert ou chargeur
  débranché, réseau revenu après une coupure, data au-delà du seuil, récap de
  fin de session.
- **Live Activity** sur l'écran verrouillé et dans la Dynamic Island : temps
  restant, batterie, agents, avec les boutons +1 h et Arrêter. Faute de serveur
  de push, elle démarre quand tu ouvres l'app pendant une session, ou quand tu
  lances la session depuis l'iPhone.
- **Widgets** pour l'écran d'accueil et l'écran verrouillé.
- **Siri** : « Prolonge la session avec DarraOwl » (une heure de plus),
  « Arrête la session avec DarraOwl », « Démarre une session avec DarraOwl »,
  « État de la session avec DarraOwl ».
- **Connexion** : chiffrée en TLS, avec une clé par iPhone appairé. Sur le même
  Wi-Fi, sur le partage de connexion de l'iPhone ou via Tailscale, elle est
  directe. Sinon, elle passe par ta base iCloud privée. Chaque commande est
  signée, expire au bout de 60 s et ne s'exécute qu'une fois.
- **Désappairer** depuis le Mac coupe aussitôt les commandes et la connexion
  directe de cet iPhone, qui oublie ce Mac dès qu'il reçoit son état suivant.
  Depuis l'iPhone, le Mac est prévenu et oublie ses clés s'il est allumé et
  joignable dans la minute ; sinon, retire aussi l'iPhone dans DarraOwl >
  iPhone… sur le Mac. L'état publié dans
  ta base iCloud reste lisible par les appareils connectés à ton compte
  iCloud, comme le reste de tes données iCloud.

## Apple Watch

L'app Watch s'installe avec l'app iPhone. Elle montre la session, les agents
et la batterie, et permet de démarrer, prolonger ou arrêter une session, de
suivre un agent, d'activer « Toujours actif », d'éteindre l'écran, de
verrouiller et de couper le son. Siri sur la montre comprend les mêmes
phrases que sur l'iPhone. Une complication affiche le temps restant sur le
cadran.

La montre passe par l'iPhone : c'est lui qui signe les commandes avec ses
clés. Ce qui demande Face ID (veille, arrêt d'un conteneur ou d'un agent)
reste sur l'iPhone.

## Sans Wi-Fi

Pour que le Mac rejoigne tout seul le partage de connexion de ton iPhone quand
il perd le Wi-Fi, capot fermé compris : Réglages Système > Wi-Fi > **Proposer
des partages de connexion** > **Automatique**. Il faut la même Apple ID sur
le Mac et l'iPhone, avec le Bluetooth et le Wi-Fi activés. DarraOwl compte
alors la data de la session et te prévient au-delà du seuil choisi dans les
alertes.

## Mode agent

Pour qu'une tâche longue finisse capot fermé, sans deviner sa durée : le Mac
reste éveillé tant que l'agent tourne, puis retrouve sa veille normale. Il y a
toujours une heure de fin : au plus la durée maximale des Réglages.

- **Menu** : la section Agents liste claude, codex et gemini en cours, avec
  leur projet. Clique sur **Suivre**.
- **iPhone** : même liste, même bouton **Suivre**.
- **Terminal** : voir ci-dessous.

Si une session minutée était déjà en cours, elle dure jusqu'à son heure de
fin prévue ou jusqu'à la fin de l'agent, selon ce qui arrive en dernier.
Plusieurs agents peuvent être suivis : la session s'arrête avec le dernier.

## Terminal

DarraOwl > Réglages > Terminal > **Installer la commande** crée le lien
`~/.local/bin/darraowl` (sans `sudo`).

```bash
darraowl run 3h -- claude     # éveillé tant que claude tourne, au plus 3 h
darraowl run -- npm test      # au plus la durée maximale
darraowl start 2h             # session minutée
darraowl extend 1h
darraowl status
darraowl stop
```

`darraowl run` lance la commande dans ton terminal, comme si tu l'avais tapée,
et rend son code de sortie. Si DarraOwl ne peut pas garder le Mac éveillé
(batterie sous le seuil, composant système absent), la commande n'est pas
lancée. Seul le nom de la commande est affiché sur l'iPhone, jamais ses
arguments.

## Claude Code

DarraOwl > Réglages > Claude Code > **Activer**. Tu reçois alors « Claude a
fini » ou « Claude attend ta validation », avec le nom du projet, quand
personne n'est devant le Mac (capot fermé ou une minute sans activité).

Le bouton ajoute deux « hooks » (Stop et Notification) dans
`~/.claude/settings.json`. Le reste du fichier est gardé, réécrit avec les
clés dans l'ordre alphabétique. Ta version d'avant DarraOwl est d'abord copiée
dans `~/.claude/settings.json.darraowl-backup`.
**Désactiver** retire exactement ces deux entrées. Les sessions de Claude
déjà ouvertes en tiennent compte à leur prochain lancement.

Le Mac n'écoute que sur `127.0.0.1:52526` et exige un jeton, rangé dans le
trousseau. Seuls l'événement, son type et le nom du dossier sont lus, jamais
le contenu.

Les noms de projets peuvent être masqués dans les réglages des alertes.

## Ce que DarraOwl modifie

| Réglage | Pendant la session | Retour |
|---|---|---|
| `pmset -a disablesleep` | 1 | la valeur d'avant |
| `pmset -b/-c lowpowermode` | 1, sous le seuil de batterie, en cas de chaleur ou capot fermé (réglable, jamais avec un écran externe), sur les Mac qui le proposent | la valeur d'avant, pour chaque profil |

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

Avec une version téléchargée : arrête la session, quitte DarraOwl, remplace
l'app dans Applications, puis rouvre-la. Remplacée pendant une session, l'app
ne pourrait plus piloter le composant système jusqu'à la fin de la session.

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

La désinstallation supprime aussi les clés d'appairage, les données
iCloud de DarraOwl, ses hooks dans `~/.claude/settings.json`, le lien
`~/.local/bin/darraowl` et les fichiers du composant système. Le script ne
lance jamais `sudo`. Si la veille n'a pas pu être rétablie, il affiche la
commande exacte à lancer.

Sans le code source (version téléchargée), lance dans le Terminal :

```bash
/Applications/DarraOwl.app/Contents/MacOS/DarraOwl --uninstall
```

puis mets l'app à la corbeille. Ne la mets pas à la corbeille directement :
le composant système resterait installé.

## Développement

```bash
swift test --package-path shared
swift test --package-path mac
swift test --package-path ios
scripts/build-mac.sh Debug
```

Les tests utilisent des faux : ils ne lancent jamais `pmset`, iCloud ni le
réseau. À part, `swift run --package-path tools/link-e2e` vérifie la liaison
de bout en bout sur ce Mac, avec la vraie pile réseau (sockets locales et
Bonjour) : ce n'est pas un test unitaire.

## Licence

[MIT](LICENSE). Des parties sont adaptées d'Insomnia (MIT), voir [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
