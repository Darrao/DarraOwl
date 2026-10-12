# Politique de confidentialité de DarraOwl

Dernière mise à jour : 12 octobre 2026

DarraOwl se compose d'une app pour Mac et d'une app pour iPhone. Elles
communiquent directement entre elles, ou via ta propre base de données iCloud
privée. **Le développeur ne collecte aucune donnée.** Aucun serveur tiers
n'intervient, et l'app ne contient ni publicité, ni outil de mesure
d'audience, ni pistage.

## Ce qui reste sur tes appareils

- Les clés d'appairage : elles sont dans le trousseau de chaque appareil et ne
  sont jamais synchronisées.
- Le journal des changements faits sur le Mac (veille, luminosité, son, apps
  mises en pause) : il est stocké sur le Mac.
- Les réglages.

## Ce qui passe par ta base iCloud privée

Seulement quand un iPhone est appairé. L'état du Mac y est publié à chaque
changement et au moins chaque minute, pour que l'iPhone le voie même loin du
Mac ; les commandes y passent quand la connexion directe ne répond pas :

- l'état du Mac : son nom, session en cours, batterie, température, capot,
  type de réseau et data consommée, noms des agents de code en cours (claude,
  codex, gemini) et de leurs dossiers de projet, noms des conteneurs Docker en
  cours (le masquage des noms de projets, dans les réglages, les remplace
  aussi), en mode agent le nom de la commande suivie (jamais ses arguments),
  noms des apps mises en pause, « Toujours actif » et son coupé ou non,
  réglages de DarraOwl (dont la liste des apps à mettre en pause) et
  identifiants des iPhone appairés ;
- les adresses réseau du Mac (locale, Tailscale), pour la connexion directe ;
- les commandes envoyées par l'iPhone, signées, et leurs résultats ;
- le titre et le texte des notifications (par exemple « Claude a fini », avec
  le nom du projet).

Ces données sont enregistrées dans ta base de données iCloud **privée**, que
seul ton compte Apple peut lire. Le contenu des états et des commandes est
chiffré par iCloud. Le développeur n'y a pas accès.

DarraOwl n'envoie **jamais** le contenu de tes fichiers, tes prompts ni ce que
produisent tes agents de code. Pour les hooks de Claude Code, seuls le nom de
l'événement, son type et le nom du dossier sont lus. Ces hooks ne sont ajoutés à
`~/.claude/settings.json` que si tu cliques sur Activer.

## Mises à jour de l'app Mac

Une fois par jour, l'app Mac demande à GitHub
(github.com/Darrao/DarraOwl) s'il existe une nouvelle version, et la
télécharge s'il y en a une. GitHub voit alors l'adresse IP du Mac, comme pour
toute visite d'une page web. Rien d'autre n'est envoyé. Tu peux couper cette
vérification dans DarraOwl > Réglages > Mises à jour.

## Apple Watch

L'iPhone transmet à ta montre l'état du Mac par la liaison Bluetooth et Wi-Fi
entre l'iPhone et la montre (WatchConnectivity). La montre ne garde aucune clé :
elle demande à l'iPhone d'envoyer les commandes.

## Réseau local, caméra, Face ID, notifications

- **Réseau local** : pour joindre ton Mac directement. La connexion est
  chiffrée (TLS) avec une clé propre à chaque iPhone appairé.
- **Caméra** : uniquement pour scanner le code d'appairage. Aucune image n'est
  conservée.
- **Face ID** : il confirme les commandes sensibles. La vérification a lieu sur
  l'iPhone, dans la Secure Enclave. DarraOwl ne voit jamais ton visage.
- **Notifications** : elles sont envoyées par iCloud, sur demande du Mac, sans
  serveur du développeur.

## Supprimer tes données

- Sur l'iPhone : « Désappairer cet iPhone ». Les clés sont effacées du
  trousseau et le Mac est prévenu s'il est allumé et joignable dans la
  minute (sinon, retire aussi l'iPhone sur le Mac). Supprimer l'app sans désappairer laisse
  ses clés dans le trousseau de l'iPhone (iOS les garde) et le Mac continue de
  publier son état : désappaire d'abord, ou retire l'iPhone sur le Mac
  (DarraOwl > iPhone…).
- Sur le Mac : `scripts/uninstall.sh`. Il supprime les clés d'appairage et les
  données iCloud de DarraOwl. Le Mac ne publie plus rien dans iCloud dès
  qu'aucun iPhone n'est appairé.
- Tu peux aussi effacer les données d'iCloud dans Réglages > [ton nom] >
  iCloud > Gérer le stockage.

## Contact

Pour toute question, ouvre un ticket sur
https://github.com/Darrao/DarraOwl/issues.
