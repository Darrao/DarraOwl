# DarraOwl

Garde ton MacBook éveillé, capot fermé compris, pendant une durée limitée.
Chaque session a une heure de fin. À cette heure-là, la veille revient, même si
l'app a planté ou a été quittée.

État : phase 1 (le cœur côté Mac). L'app iPhone, la liaison et le mode capot
fermé arrivent dans les phases suivantes.

> Pose le Mac sur une surface stable et ventilée, jamais dans un sac fermé.

## Installation

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

## iPhone (en cours : phase 3)

Le Mac est prêt à être piloté depuis l'iPhone. L'app iPhone arrive en
phase 3b.

- **Appairage** : DarraOwl > **iPhone…** > **Afficher le code d'appairage**.
  Le code QR est valable 5 minutes et ne sert qu'une fois. Les clés
  d'appairage restent dans le trousseau de ce Mac.
- **Connexion directe** : sur le même Wi-Fi ou sur le partage de connexion de
  l'iPhone, la connexion est chiffrée en TLS, avec une clé par iPhone
  appairé. Le Mac est trouvé par Bonjour (`_darraowl._tcp`, port 52525).
- **iCloud** : sinon, tout passe par ta base iCloud privée (conteneur
  `iCloud.com.darrao.darraowl`). Le Mac y publie son état à chaque
  changement, et au moins une fois par minute. Il y lit les commandes et y
  écrit leurs résultats. Le contenu est chiffré par iCloud (`encryptedValues`).
  Aucun serveur tiers n'intervient.
- **Commandes** : la liste est fermée : démarrer, prolonger, arrêter, mettre
  en veille, Docker, réglages. Chaque commande est signée par l'iPhone,
  expire au bout de 60 s et ne s'exécute qu'une fois. Mettre en veille ou
  arrêter un conteneur demande Face ID.
- **Désappairer**, dans la même fenêtre, coupe l'accès de l'iPhone
  immédiatement.

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
réseau. Les règles du projet sont dans [CLAUDE.md](CLAUDE.md).

## Licence

[MIT](LICENSE). Des parties sont adaptées d'Insomnia (MIT), voir [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
