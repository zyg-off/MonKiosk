# MonKiosk

L'outil de gestion des petits commerces : planning d'équipe, congés, annonces, checklists d'ouverture et de fermeture, relevés de température, stock et ventes.

## Utiliser MonKiosk

- **En ligne et sur téléphone** : https://zyg-off.github.io/MonKiosk/
  Sur téléphone, ajoute la page à l'écran d'accueil pour l'installer comme une appli.
- **Sur PC Windows** : [télécharger l'installateur](https://github.com/zyg-off/MonKiosk/releases/latest/download/MonKiosk-Installer.exe). Ce lien donne toujours la dernière version, et l'appli se met ensuite à jour toute seule.

Chaque commerce a son compte. Les données sont enregistrées en ligne et synchronisées en direct entre le site, le téléphone et l'appli PC. Le bouton *Découvrir la démo* ouvre un exemple sans rien enregistrer.

## Organisation du projet

- `web/` : l'application (une seule page HTML). C'est la version en ligne.
- `desktop/` : l'application Windows, qui reprend automatiquement le contenu de `web/`.
- `supabase/schema.sql` : la base de données complète (comptes, commerces, salariés, sécurité), pour une nouvelle installation.
- `supabase/migration-1.4.sql`, `migration-1.5.sql`, `migration-1.6.sql`, `migration-1.7.sql` et `migration-1.8.sql` : les mises à jour de la base (comptes salariés, options, code de pointage, pertes par produit).

## Administration

Les options avancées (espace salarié, badgeuse, coût salarial, registre PDF, statistiques) sont débloquées commerce par commerce par l'équipe MonKiosk, depuis *Compte > Administration MonKiosk*. Pour devenir administrateur, exécuter une fois dans Supabase :

```sql
insert into public.platform_admins (user_id) select id from auth.users where email = 'ADRESSE_DU_COMPTE';
```
- `web/config.js` : l'adresse du projet Supabase et sa clé publique.

## Publier une nouvelle version

1. Modifier l'application dans `web/`.
2. Changer le numéro de version dans `desktop/package.json` (par exemple `1.1.0`).
3. Envoyer les modifications sur `main`.
   GitHub construit l'installateur Windows et crée la release `v1.1.0`. La version en ligne se met à jour à chaque modification de `web/`.
