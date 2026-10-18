# Drzewo rodziny

Prosta aplikacja do wspólnego uzupełniania drzewa genealogicznego. Działa w przeglądarce telefonu i komputera.

- `index.html` – cała aplikacja (strona statyczna, hostowana na GitHub Pages).
- `supabase/schema.sql` – tabele i funkcje bazy w Supabase.

Dane rodziny **nie** są przechowywane w tym repozytorium. Leżą w bazie Supabase i są dostępne
tylko przez funkcje, które sprawdzają hasło (rodzinne albo administratora).

Jak to działa:
- Rodzina wchodzi z linku i wpisuje hasło rodzinne. Każda zmiana jest od razu widoczna dla autora,
  a dla pozostałych dopiero po zatwierdzeniu.
- Administrator wchodzi tym samym linkiem, ale wpisuje hasło administratora – widzi zakładkę
  „Do zatwierdzenia”, może zatwierdzać, odrzucać, poprawiać i cofać zmiany.
- Powiadomienia o nowych zmianach przychodzą na telefon przez aplikację ntfy.

Zmiana haseł (Supabase → SQL Editor):

```sql
select public.tree_setup('nowe-haslo-rodzinne', 'nowe-haslo-administratora', '<temat ntfy>', '<adres strony>');
```
