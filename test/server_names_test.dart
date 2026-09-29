// Одинаковые имена серверов (бесплатная подписка igareck: 43 разных имени
// на 150 серверов) делаются различимыми. Тест зовёт настоящую функцию.

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_app_test/main.dart';

ParsedServer _s(String name) =>
    ParsedServer(name: name, protocol: 'vless', outbound: {'type': 'vless'})..link = 'vless://$name';

void main() {
  test('namesakes get (2), (3); unique names stay as they are', () {
    final out = dedupeServerNames([
      _s('Frankfurt'),
      _s('Amsterdam'),
      _s('Frankfurt'),
      _s('Frankfurt'),
    ]);
    expect(out.map((s) => s.name), ['Frankfurt', 'Amsterdam', 'Frankfurt (2)', 'Frankfurt (3)']);
  });

  test('a name that already looks like a suffix is not collided with', () {
    final out = dedupeServerNames([_s('A'), _s('A (2)'), _s('A')]);
    expect(out.map((s) => s.name), ['A', 'A (2)', 'A (3)']);
  });

  test('the renamed server keeps everything else', () {
    final original = _s('X');
    final out = dedupeServerNames([_s('X'), original]);
    expect(out[1].name, 'X (2)');
    expect(identical(out[1].outbound, original.outbound), isTrue);
    expect(out[1].link, original.link);
    expect(out[1].engine, original.engine);
  });

  test('a list without namesakes is returned as is', () {
    final list = [_s('A'), _s('B')];
    final out = dedupeServerNames(list);
    expect(identical(out[0], list[0]) && identical(out[1], list[1]), isTrue);
  });
}
