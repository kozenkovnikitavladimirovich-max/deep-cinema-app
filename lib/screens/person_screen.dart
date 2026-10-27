import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/models.dart';
import '../data/tmdb.dart';
import '../widgets/common.dart';
import '../widgets/focusable.dart';
import '../widgets/person_photo.dart';
import 'details_screen.dart';
import '../widgets/routes.dart';

/// Круглое фото человека (или инициалы, пока фото нет).
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, required this.person, required this.size});
  final Person person;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(shape: BoxShape.circle, color: c.chip),
      child: PersonPhoto(
        url: person.photoUrl,
        size: size,
        fallback: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(gradient: MediaTitle.faceFor(person.name)),
          child: Text(person.initials, style: TextStyle(color: Colors.white, fontSize: size * .3, fontWeight: FontWeight.w800)),
        ),
      ),
    );
  }
}

/// Страница человека: фото, профессия, биография и все работы.
class PersonScreen extends StatefulWidget {
  const PersonScreen({super.key, required this.person});
  final Person person;

  static Future<void> open(BuildContext context, Person p) => Navigator.of(context).push(
        dcRoute((_) => PersonScreen(person: p)),
      );

  @override
  State<PersonScreen> createState() => _PersonScreenState();
}

class _PersonScreenState extends State<PersonScreen> {
  late Future<PersonDetails> _f = Tmdb.instance.person(widget.person.id);
  bool _bioOpen = false;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return Scaffold(
      backgroundColor: c.bg,
      body: FutureBuilder<PersonDetails>(
        future: _f,
        builder: (context, snap) {
          final d = snap.data;
          return CustomScrollView(cacheExtent: 1400, slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(72, 110, 72, 0),
              sliver: SliverToBoxAdapter(
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  PersonAvatar(person: Person(id: widget.person.id, name: widget.person.name, profilePath: d?.person.profilePath ?? widget.person.profilePath), size: 200),
                  const SizedBox(width: 40),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const SizedBox(height: 24),
                      if (d != null && d.department.isNotEmpty)
                        Text(d.department.toUpperCase(), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: c.muted)),
                      const SizedBox(height: 10),
                      Text(widget.person.name, style: const TextStyle(fontSize: 60, height: 1.02, fontWeight: FontWeight.w800, letterSpacing: -2)),
                      if (d != null && d.person.name != widget.person.name) Text(d.person.name, style: TextStyle(fontSize: 18, color: c.muted)),
                      const SizedBox(height: 14),
                      if (d != null && d.biography.isNotEmpty)
                        Focusable(
                          onTap: () => setState(() => _bioOpen = !_bioOpen),
                          radius: 12,
                          scale: 1.01,
                          child: SizedBox(
                            width: 820,
                            child: Text(
                              d.biography,
                              maxLines: _bioOpen ? 40 : 4,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 16, height: 1.55, color: c.muted),
                            ),
                          ),
                        ),
                      if (d != null) ...[
                        const SizedBox(height: 14),
                        Text('${d.credits.length} работ в каталоге', style: TextStyle(fontSize: 15, color: c.muted)),
                      ],
                    ]),
                  ),
                ]),
              ),
            ),
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(72, 40, 72, 0),
              sliver: SliverToBoxAdapter(child: Text('Фильмография', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: Color(0x99F5F5F7)))),
            ),
            if (snap.hasError)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: ErrorPanel(message: snap.error.toString(), onRetry: () => setState(() => _f = Tmdb.instance.person(widget.person.id))),
                ),
              )
            else if (d == null)
              const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())))
            else
              PosterSliverGrid(
                items: [for (final e in d.credits) e.$1],
                subtitleFor: (t) {
                  final role = d.credits.firstWhere((e) => e.$1.id == t.id).$2;
                  return [if (t.year > 0) '${t.year}', role].join(' · ');
                },
                onTap: (t) => DetailsScreen.open(context, t),
              ),
          ]);
        },
      ),
    );
  }
}
