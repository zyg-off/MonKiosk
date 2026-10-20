# MonKiosk

L'outil de gestion des petits commerces : planning d'équipe, congés, annonces, checklists d'ouverture et de fermeture, relevés de température, stock et ventes.

## Utiliser MonKiosk

- **En ligne et sur téléphone** : https://zyg-off.github.io/MonKiosk/
  Sur téléphone, ajoute la page à l'écran d'accueil pour l'installer comme une appli.
- **Sur PC Windows** : télécharge `MonKiosk-Setup.exe` dans la page [Releases](https://github.com/zyg-off/MonKiosk/releases).

Les données restent sur chaque appareil. Pour passer de l'un à l'autre, utilise *Exporter mes données* puis *Importer une sauvegarde* sur l'Accueil.

## Organisation du projet

- `web/` : l'application (une seule page HTML). C'est la version en ligne.
- `desktop/` : l'application Windows, qui reprend automatiquement le contenu de `web/`.

## Publier une nouvelle version

1. Modifier l'application dans `web/`.
2. Changer le numéro de version dans `desktop/package.json` (par exemple `1.1.0`).
3. Envoyer les modifications sur `main`.
   GitHub construit l'installateur Windows et crée la release `v1.1.0`. La version en ligne se met à jour à chaque modification de `web/`.
