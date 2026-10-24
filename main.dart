// Mensajes sin internet - Versión 3
// - Registro con nombre y número de celular
// - Chats privados por número
// - Dentro del chat: "en línea" o "últ. vez hoy a las ..."
// - Envío reforzado:
//     1) Bluetooth + Wi-Fi Direct (red mesh: los mensajes saltan de teléfono en teléfono)
//     2) Si no llega en 20 segundos y hay señal de celular: se manda por SMS (sin datos)
//     3) Si no se pudo de ninguna forma: se queda guardado y se reintenta solo
// - Los teléfonos guardan mensajes de otros y los entregan cuando se encuentran (guardar y reenviar)
// - Pantalla "Estado de conexión" para ver qué está fallando

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _nativo = MethodChannel('msi/nativo');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(MensajesApp(red: Red(prefs)));
}

// ---------- Utilidades ----------

int _ahora() => DateTime.now().millisecondsSinceEpoch;

/// Deja solo los últimos 10 dígitos del número.
String limpiarTel(String t) {
  final d = t.replaceAll(RegExp(r'\D'), '');
  return d.length > 10 ? d.substring(d.length - 10) : d;
}

String _hm(DateTime d) {
  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final mm = d.minute.toString().padLeft(2, '0');
  return '$h12:$mm ${d.hour < 12 ? 'a.m.' : 'p.m.'}';
}

/// "9:17 p.m." si es de hoy, "22/10 9:17 p.m." si es de otro día.
String horaTexto(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final hoy = DateTime.now();
  final esHoy = d.year == hoy.year && d.month == hoy.month && d.day == hoy.day;
  return esHoy ? _hm(d) : '${d.day}/${d.month} ${_hm(d)}';
}

/// "últ. vez hoy a las 7:09 p.m."
String ultimaVezTexto(int? ms) {
  if (ms == null) return 'sin conexión todavía';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final hoy = DateTime.now();
  final dif = DateTime(hoy.year, hoy.month, hoy.day)
      .difference(DateTime(d.year, d.month, d.day))
      .inDays;
  final cuando = dif == 0 ? 'hoy' : (dif == 1 ? 'ayer' : '${d.day}/${d.month}');
  return 'últ. vez $cuando a las ${_hm(d)}';
}

// ---------- Modelos ----------

enum Estado { pendiente, enviado, entregado }

class Mensaje {
  Mensaje({
    required this.id,
    required this.de,
    required this.deNombre,
    required this.para,
    required this.texto,
    required this.hora,
    this.estado = Estado.pendiente,
    this.viaSms = false,
  });

  final String id;
  final String de; // número de quien lo escribió
  final String deNombre;
  final String para; // número de quien lo recibe
  final String texto;
  final int hora; // cuándo se escribió
  Estado estado;
  bool viaSms; // se mandó (o llegó) por SMS

  Map<String, dynamic> toJson() => {
        'id': id,
        'de': de,
        'deNombre': deNombre,
        'para': para,
        'texto': texto,
        'hora': hora,
        'estado': estado.index,
        'sms': viaSms,
      };

  factory Mensaje.fromJson(Map<String, dynamic> j) => Mensaje(
        id: j['id'] as String,
        de: j['de'] as String,
        deNombre: (j['deNombre'] ?? '') as String,
        para: j['para'] as String,
        texto: j['texto'] as String,
        hora: (j['hora'] as num).toInt(),
        estado: Estado.values[((j['estado'] ?? 0) as num).toInt()],
        viaSms: (j['sms'] ?? false) as bool,
      );
}

class Vecino {
  Vecino(this.nombre, this.tel);
  final String nombre;
  final String tel;
}

// ---------- La red (toda la lógica) ----------

class Red extends ChangeNotifier with WidgetsBindingObserver {
  Red(this._prefs) {
    miNombre = _prefs.getString('yo_nombre') ?? '';
    miTel = _prefs.getString('yo_tel') ?? '';
    usarSms = _prefs.getBool('usar_sms') ?? true;
    try {
      final c = _prefs.getString('contactos');
      if (c != null) {
        (jsonDecode(c) as Map<String, dynamic>)
            .forEach((tel, nombre) => contactos[tel] = nombre as String);
      }
      final m = _prefs.getString('mensajes');
      if (m != null) {
        for (final x in jsonDecode(m) as List) {
          mensajes.add(Mensaje.fromJson(Map<String, dynamic>.from(x as Map)));
        }
      }
      final u = _prefs.getString('ultima_vez');
      if (u != null) {
        (jsonDecode(u) as Map<String, dynamic>)
            .forEach((tel, ms) => ultimaVez[tel] = (ms as num).toInt());
      }
      final b = _prefs.getString('buzon');
      if (b != null) {
        (jsonDecode(b) as Map<String, dynamic>)
            .forEach((k, v) => _buzon[k] = Map<String, dynamic>.from(v as Map));
      }
    } catch (_) {
      // si algo guardado está dañado, seguimos con lo que se pudo leer
    }
  }

  static const _servicio = 'com.davy.mensajes_sin_internet';
  static const _saltos = 6; // cuántas veces puede saltar un paquete
  static const _enLineaMs = 45000; // si supimos de él hace menos de 45 s, está "en línea"
  final _strategy = Strategy.P2P_CLUSTER;
  final SharedPreferences _prefs;

  String miNombre = '';
  String miTel = '';
  bool usarSms = true;
  final Map<String, String> contactos = {}; // número -> nombre
  final List<Mensaje> mensajes = [];
  final Map<String, int> noLeidos = {};
  final Map<String, int> ultimaVez = {}; // número -> última vez que supimos de él
  final Map<String, Vecino> conectados = {}; // endpointId -> vecino
  String estadoRed = 'Preparando...';
  final List<String> eventos = [];
  Map<String, bool> radios = {};
  Map<String, String> permisos = {};
  bool anunciando = false;
  bool buscando = false;

  final Map<String, Vecino> _porConectar = {};
  final Set<String> _conectando = {};
  final Map<String, int> _intentos = {};
  final Set<String> _vistos = {}; // paquetes que ya pasaron por aquí
  final Map<String, Map<String, dynamic>> _buzon = {}; // paquetes de otros que cargo
  final Map<String, int> _ultimoIntentoSms = {};
  final Set<String> _enviandoSms = {};
  bool _iniciada = false;
  bool _reiniciando = false;
  Timer? _reloj;
  int _ultimoReenvio = 0;
  int _ultimoPing = 0;
  int _sinNadieDesde = 0;

  bool get registrado => miTel.isNotEmpty;
  String get _miEndpoint => '$miNombre|$miTel';

  bool enLinea(String tel) {
    if (conectados.values.any((v) => v.tel == tel)) return true;
    final u = ultimaVez[tel];
    return u != null && _ahora() - u < _enLineaMs;
  }

  String estadoDe(String tel) => enLinea(tel) ? 'en línea' : ultimaVezTexto(ultimaVez[tel]);

  List<Mensaje> chatCon(String tel) => mensajes
      .where((m) => (m.de == miTel && m.para == tel) || (m.de == tel && m.para == miTel))
      .toList();

  Mensaje? ultimoCon(String tel) {
    final l = chatCon(tel);
    return l.isEmpty ? null : l.last;
  }

  List<String> get chatsOrdenados {
    final l = contactos.keys.toList();
    l.sort((a, b) => (ultimoCon(b)?.hora ?? 0).compareTo(ultimoCon(a)?.hora ?? 0));
    return l;
  }

  Future<void> registrar(String nombre, String tel) async {
    miNombre = nombre.replaceAll('|', ' ').trim();
    miTel = tel;
    await _prefs.setString('yo_nombre', miNombre);
    await _prefs.setString('yo_tel', miTel);
    notifyListeners();
  }

  void agregarContacto(String tel, String nombre) {
    contactos[tel] = nombre;
    _guardar();
    notifyListeners();
  }

  void cambiarUsarSms(bool v) {
    usarSms = v;
    _prefs.setBool('usar_sms', v);
    notifyListeners();
  }

  void _guardar() {
    _prefs.setString('contactos', jsonEncode(contactos));
    _prefs.setString('mensajes', jsonEncode(mensajes.map((m) => m.toJson()).toList()));
  }

  void _guardarUltimaVez() => _prefs.setString('ultima_vez', jsonEncode(ultimaVez));
  void _guardarBuzon() => _prefs.setString('buzon', jsonEncode(_buzon));

  void _log(String s) {
    eventos.insert(0, '${_hm(DateTime.now())}  $s');
    if (eventos.length > 60) eventos.removeLast();
    estadoRed = s;
    notifyListeners();
  }

  String _nuevoId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${Random().nextInt(1679616).toRadixString(36)}';

  Vecino _vecinoDe(String endpointName) {
    final i = endpointName.lastIndexOf('|');
    if (i < 0) return Vecino(endpointName, '');
    return Vecino(endpointName.substring(0, i), endpointName.substring(i + 1));
  }

  // ===== Arranque =====

  Future<void> iniciar() async {
    if (_iniciada) return;
    _iniciada = true;
    WidgetsBinding.instance.addObserver(this);

    await [
      Permission.location,
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.nearbyWifiDevices,
      Permission.sms,
    ].request();

    await actualizarDiagnostico();
    if (radios['bluetooth'] == false) _log('⚠️ El Bluetooth está apagado');
    if (radios['ubicacion'] == false) _log('⚠️ La Ubicación (GPS) está apagada');

    await _encenderRed();
    _reloj ??= Timer.periodic(const Duration(seconds: 5), (_) => _tick());
    _tick();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _tick();
  }

  Future<void> _encenderRed() async {
    anunciando = false;
    buscando = false;
    try {
      await Nearby().startAdvertising(
        _miEndpoint,
        _strategy,
        onConnectionInitiated: _alIniciar,
        onConnectionResult: _alResultado,
        onDisconnected: _alDesconectar,
        serviceId: _servicio,
      );
      anunciando = true;
    } catch (e) {
      _log('Error al anunciarse: $e');
    }
    try {
      await Nearby().startDiscovery(
        _miEndpoint,
        _strategy,
        onEndpointFound: _alEncontrar,
        onEndpointLost: (id) => _log('Se perdió la señal de un teléfono'),
        serviceId: _servicio,
      );
      buscando = true;
    } catch (e) {
      _log('Error al buscar: $e');
    }
    if (anunciando && buscando) _log('Buscando teléfonos cercanos...');
    _sinNadieDesde = _ahora();
  }

  Future<void> _apagarRed() async {
    try {
      await Nearby().stopAdvertising();
    } catch (_) {}
    try {
      await Nearby().stopDiscovery();
    } catch (_) {}
    try {
      await Nearby().stopAllEndpoints();
    } catch (_) {}
    for (final v in conectados.values) {
      if (v.tel.isNotEmpty) ultimaVez[v.tel] = _ahora();
    }
    _guardarUltimaVez();
    conectados.clear();
    _conectando.clear();
    _porConectar.clear();
    _intentos.clear();
    anunciando = false;
    buscando = false;
  }

  /// Botón "Reiniciar conexión".
  Future<void> reiniciar() async {
    if (_reiniciando) return;
    _reiniciando = true;
    _log('Reiniciando conexión...');
    await _apagarRed();
    await Future<void>.delayed(const Duration(seconds: 1));
    await _encenderRed();
    _reiniciando = false;
    notifyListeners();
  }

  /// Se ejecuta cada 5 segundos: reintentos, SMS, "en línea", etc.
  Future<void> _tick() async {
    final ahora = _ahora();
    await _leerSms();

    if (conectados.isNotEmpty) {
      _sinNadieDesde = ahora;
      if (ahora - _ultimoPing > 15000) {
        _ultimoPing = ahora;
        _mandarPing();
      }
      if (ahora - _ultimoReenvio > 30000) {
        _ultimoReenvio = ahora;
        _reenviarPendientes();
      }
    } else if (!_reiniciando && _conectando.isEmpty && ahora - _sinNadieDesde > 60000) {
      // A veces la búsqueda de Android se "atora": la reiniciamos cada minuto si no hay nadie
      _reiniciando = true;
      await _apagarRed();
      await _encenderRed();
      _reiniciando = false;
    }

    if (usarSms) await _revisarSms(ahora);
    notifyListeners(); // refresca "en línea" / "últ. vez"
  }

  // ===== Conexión con teléfonos cercanos =====

  void _alEncontrar(String id, String endpointName, String serviceId) {
    if (conectados.containsKey(id) || _conectando.contains(id)) return;
    final v = _vecinoDe(endpointName);
    _log('Encontré a ${v.nombre}, conectando...');
    // Para no chocar, pide la conexión primero el del número menor; el otro espera 6 s.
    if (miTel.compareTo(v.tel) < 0) {
      _pedirConexion(id);
    } else {
      Timer(const Duration(seconds: 6), () => _pedirConexion(id));
    }
  }

  void _pedirConexion(String id) {
    if (conectados.containsKey(id) || _conectando.contains(id)) return;
    final intentos = (_intentos[id] ?? 0) + 1;
    if (intentos > 5) {
      _log('No se pudo conectar después de 5 intentos');
      return;
    }
    _intentos[id] = intentos;
    _conectando.add(id);
    Nearby()
        .requestConnection(
      _miEndpoint,
      id,
      onConnectionInitiated: _alIniciar,
      onConnectionResult: _alResultado,
      onDisconnected: _alDesconectar,
    )
        .catchError((Object e) {
      _conectando.remove(id);
      _log('No se pudo conectar (intento $intentos): $e');
      Timer(Duration(seconds: 3 + Random().nextInt(5)), () => _pedirConexion(id));
      return false;
    });
  }

  void _alIniciar(String id, ConnectionInfo info) {
    _conectando.add(id);
    _porConectar[id] = _vecinoDe(info.endpointName);
    Nearby().acceptConnection(id, onPayLoadRecieved: _alRecibir).catchError((Object e) {
      _log('Error al aceptar conexión: $e');
      return false;
    });
  }

  void _alResultado(String id, Status status) {
    _conectando.remove(id);
    final v = _porConectar.remove(id);
    if (status == Status.CONNECTED && v != null) {
      conectados[id] = v;
      _intentos.remove(id);
      if (v.tel.isNotEmpty) {
        ultimaVez[v.tel] = _ahora();
        if (contactos[v.tel] == v.tel) contactos[v.tel] = v.nombre;
        _guardarUltimaVez();
      }
      _log('Conectado con ${v.nombre}');
      _mandarPing();
      _entregarBuzon(id);
      _reenviarPendientes();
    } else {
      _log('La conexión falló, reintentando...');
      Timer(Duration(seconds: 3 + Random().nextInt(5)), () => _pedirConexion(id));
    }
  }

  void _alDesconectar(String id) {
    final v = conectados.remove(id);
    if (v != null && v.tel.isNotEmpty) {
      ultimaVez[v.tel] = _ahora();
      _guardarUltimaVez();
    }
    _log('${v?.nombre ?? 'Alguien'} se desconectó');
  }

  // ===== Enviar =====

  void enviar(String para, String texto) {
    final m = Mensaje(
      id: _nuevoId(),
      de: miTel,
      deNombre: miNombre,
      para: para,
      texto: texto,
      hora: _ahora(),
    );
    mensajes.add(m);
    _mandar(m);
    _guardar();
    notifyListeners();
  }

  Uint8List _bytes(Map<String, dynamic> p) => Uint8List.fromList(utf8.encode(jsonEncode(p)));

  void _difundir(Map<String, dynamic> p, {String? excepto}) {
    final bytes = _bytes(p);
    for (final id in conectados.keys.toList()) {
      if (id == excepto) continue;
      Nearby().sendBytesPayload(id, bytes).catchError((Object _) {});
    }
  }

  void _mandarA(String endpointId, Map<String, dynamic> p) {
    Nearby().sendBytesPayload(endpointId, _bytes(p)).catchError((Object _) {});
  }

  /// Manda un mensaje por la red cercana (si hay alguien).
  void _mandar(Mensaje m) {
    if (conectados.isEmpty) return; // se queda 🕓 y se reintenta solo
    final rid = _nuevoId();
    _vistos.add(rid);
    _difundir({
      't': 'msg',
      'rid': rid,
      'ttl': _saltos,
      'id': m.id,
      'de': m.de,
      'deNombre': m.deNombre,
      'para': m.para,
      'texto': m.texto,
      'hora': m.hora,
    });
    if (m.estado == Estado.pendiente) m.estado = Estado.enviado;
  }

  void _reenviarPendientes() {
    for (final m in mensajes) {
      if (m.de == miTel && m.estado != Estado.entregado) _mandar(m);
    }
    _guardar();
    notifyListeners();
  }

  void _mandarPing() {
    final rid = _nuevoId();
    _vistos.add(rid);
    _difundir({'t': 'ping', 'rid': rid, 'ttl': _saltos, 'de': miTel, 'nombre': miNombre});
  }

  void _enviarAcuse(String msgId, String para) {
    final rid = _nuevoId();
    _vistos.add(rid);
    _difundir({'t': 'ack', 'rid': rid, 'ttl': _saltos, 'msgId': msgId, 'de': miTel, 'para': para});
  }

  // ===== Recibir =====

  void _alRecibir(String endpointId, Payload payload) {
    if (payload.type != PayloadType.BYTES || payload.bytes == null) return;
    Map<String, dynamic> j;
    try {
      j = Map<String, dynamic>.from(jsonDecode(utf8.decode(payload.bytes!)) as Map);
    } catch (_) {
      return;
    }
    final tipo = j['t'] as String?;
    final rid = (j['rid'] ?? j['id']) as String?;
    if (tipo == null || rid == null) return;
    if (!_vistos.add(rid)) return; // ya pasó por aquí
    final ttl = ((j['ttl'] ?? 0) as num).toInt();
    final para = j['para'] as String?;

    if (tipo == 'ping') {
      final de = j['de'] as String?;
      final nombre = j['nombre'] as String?;
      if (de != null && de.isNotEmpty && de != miTel) {
        ultimaVez[de] = _ahora();
        if (nombre != null && nombre.isNotEmpty && contactos[de] == de) {
          contactos[de] = nombre;
          _guardar();
        }
        _guardarUltimaVez();
        notifyListeners();
      }
    } else if (tipo == 'msg' && para == miTel) {
      _recibirMensaje(j);
      return;
    } else if (tipo == 'ack' && para == miTel) {
      final msgId = j['msgId'] as String?;
      var cambio = false;
      for (final m in mensajes) {
        if (m.id == msgId && m.de == miTel && m.estado != Estado.entregado) {
          m.estado = Estado.entregado;
          cambio = true;
        }
      }
      if (cambio) {
        _guardar();
        notifyListeners();
      }
      return;
    } else if (tipo == 'msg' || tipo == 'ack') {
      _guardarEnBuzon(j); // lo cargo por si me encuentro al destinatario después
    }

    // No es para mí: lo paso a los demás (red mesh)
    if (ttl > 1) {
      j['ttl'] = ttl - 1;
      _difundir(j, excepto: endpointId);
    }
  }

  void _recibirMensaje(Map<String, dynamic> j) {
    final id = j['id'] as String?;
    final de = j['de'] as String?;
    if (id == null || de == null) return;
    if (!mensajes.any((m) => m.id == id)) {
      final deNombre = (j['deNombre'] ?? de) as String;
      mensajes.add(Mensaje(
        id: id,
        de: de,
        deNombre: deNombre,
        para: miTel,
        texto: (j['texto'] ?? '') as String,
        hora: ((j['hora'] ?? _ahora()) as num).toInt(),
        estado: Estado.entregado,
      ));
      if (contactos[de] == null || contactos[de] == de) contactos[de] = deNombre;
      noLeidos[de] = (noLeidos[de] ?? 0) + 1;
      _guardar();
      notifyListeners();
    }
    _enviarAcuse(id, de); // siempre, por si el aviso anterior se perdió
  }

  // ===== Guardar y reenviar (para mensajes de otros) =====

  void _guardarEnBuzon(Map<String, dynamic> j) {
    final esAcuse = j['t'] == 'ack';
    final clave = esAcuse ? 'a:${j['msgId']}' : 'm:${j['id']}';
    if (esAcuse) {
      _buzon.remove('m:${j['msgId']}'); // ya llegó, ya no hace falta cargarlo
    } else if (_buzon.containsKey('a:${j['id']}')) {
      return; // ya sabemos que llegó
    }
    _buzon[clave] = Map<String, dynamic>.from(j)..['guardado'] = _ahora();
    final limite = _ahora() - const Duration(hours: 48).inMilliseconds;
    _buzon.removeWhere((k, v) => ((v['guardado'] ?? 0) as num).toInt() < limite);
    while (_buzon.length > 300) {
      _buzon.remove(_buzon.keys.first);
    }
    _guardarBuzon();
  }

  void _entregarBuzon(String endpointId) {
    for (final p in _buzon.values.toList()) {
      final copia = Map<String, dynamic>.from(p)..remove('guardado');
      final rid = _nuevoId();
      _vistos.add(rid);
      copia['rid'] = rid;
      copia['ttl'] = _saltos;
      _mandarA(endpointId, copia);
    }
  }

  // ===== SMS (red de celular, sin datos) =====

  Future<void> _revisarSms(int ahora) async {
    final pendientes = mensajes
        .where((m) =>
            m.de == miTel &&
            m.estado != Estado.entregado &&
            !m.viaSms &&
            !_enviandoSms.contains(m.id) &&
            ahora - m.hora > 20000 &&
            ahora - (_ultimoIntentoSms[m.id] ?? 0) > 60000)
        .toList();
    if (pendientes.isEmpty) return;
    if (!await Permission.sms.isGranted) return;
    for (final m in pendientes) {
      await _enviarPorSms(m);
    }
  }

  Future<void> _enviarPorSms(Mensaje m) async {
    _enviandoSms.add(m.id);
    _ultimoIntentoSms[m.id] = _ahora();
    var ok = false;
    try {
      ok = await _nativo.invokeMethod<bool>(
            'enviarSms',
            {'tel': m.para, 'texto': '${m.texto} [MSI:${m.id}]'},
          ) ??
          false;
    } catch (_) {
      ok = false;
    }
    _enviandoSms.remove(m.id);
    if (ok) {
      m.viaSms = true;
      if (m.estado == Estado.pendiente) m.estado = Estado.enviado;
      _guardar();
      _log('Mensaje enviado por SMS a ${contactos[m.para] ?? m.para}');
    } else {
      _log('El SMS no salió (¿sin señal o sin saldo?). Reintento en 1 minuto');
    }
  }

  Future<void> _leerSms() async {
    String? s;
    try {
      s = await _nativo.invokeMethod<String>('leerSms');
    } catch (_) {
      return;
    }
    if (s == null || s.isEmpty || s == '[]') return;
    final patron = RegExp(r'\s*\[MSI:([0-9a-z\-]+)\]\s*$');
    var hubo = false;
    try {
      for (final x in jsonDecode(s) as List) {
        final mapa = Map<String, dynamic>.from(x as Map);
        final de = limpiarTel((mapa['de'] ?? '') as String);
        final texto = (mapa['texto'] ?? '') as String;
        final hora = ((mapa['hora'] ?? _ahora()) as num).toInt();
        final r = patron.firstMatch(texto);
        if (r == null || de.isEmpty) continue;
        final id = r.group(1)!;
        if (mensajes.any((m) => m.id == id)) continue;
        contactos.putIfAbsent(de, () => de);
        mensajes.add(Mensaje(
          id: id,
          de: de,
          deNombre: contactos[de] ?? de,
          para: miTel,
          texto: texto.substring(0, r.start),
          hora: hora,
          estado: Estado.entregado,
          viaSms: true,
        ));
        noLeidos[de] = (noLeidos[de] ?? 0) + 1;
        hubo = true;
      }
    } catch (_) {}
    if (hubo) {
      _guardar();
      _log('Llegó un mensaje por SMS');
    }
  }

  // ===== Diagnóstico =====

  Future<void> actualizarDiagnostico() async {
    try {
      final r = await _nativo.invokeMapMethod<String, bool>('radios');
      if (r != null) radios = r;
    } catch (_) {
      radios = {};
    }
    Future<String> st(Permission p) async {
      final s = await p.status;
      if (s.isGranted || s.isLimited) return 'ok';
      if (s.isPermanentlyDenied) return 'bloqueado';
      return 'no';
    }

    permisos = {
      'Ubicación': await st(Permission.location),
      'Buscar dispositivos (Bluetooth)': await st(Permission.bluetoothScan),
      'Conectar Bluetooth': await st(Permission.bluetoothConnect),
      'Anunciarse por Bluetooth': await st(Permission.bluetoothAdvertise),
      'Wi-Fi cercano (Android 13+)': await st(Permission.nearbyWifiDevices),
      'SMS': await st(Permission.sms),
    };
    notifyListeners();
  }
}

// ---------- App ----------

class MensajesApp extends StatelessWidget {
  const MensajesApp({super.key, required this.red});
  final Red red;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mensajes sin internet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
      home: red.registrado ? ContactosPantalla(red: red) : RegistroPantalla(red: red),
    );
  }
}

// ---------- Registro ----------

class RegistroPantalla extends StatefulWidget {
  const RegistroPantalla({super.key, required this.red});
  final Red red;

  @override
  State<RegistroPantalla> createState() => _RegistroPantallaState();
}

class _RegistroPantallaState extends State<RegistroPantalla> {
  final _nombre = TextEditingController();
  final _tel = TextEditingController();

  Future<void> _entrar() async {
    final nombre = _nombre.text.trim();
    final tel = limpiarTel(_tel.text);
    if (nombre.isEmpty) {
      _aviso('Escribe tu nombre');
      return;
    }
    if (tel.length != 10) {
      _aviso('Escribe tu número a 10 dígitos');
      return;
    }
    await widget.red.registrar(nombre, tel);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => ContactosPantalla(red: widget.red)),
    );
  }

  void _aviso(String t) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Icon(Icons.wifi_off, size: 72),
                const SizedBox(height: 16),
                const Text('Mensajes sin internet',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                const SizedBox(height: 32),
                TextField(
                  controller: _nombre,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Tu nombre',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _tel,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Tu número de celular (10 dígitos)',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _entrar(),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(onPressed: _entrar, child: const Text('Entrar')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- Lista de chats ----------

class ContactosPantalla extends StatefulWidget {
  const ContactosPantalla({super.key, required this.red});
  final Red red;

  @override
  State<ContactosPantalla> createState() => _ContactosPantallaState();
}

class _ContactosPantallaState extends State<ContactosPantalla> {
  Red get red => widget.red;

  @override
  void initState() {
    super.initState();
    red.iniciar();
  }

  void _abrirChat(String tel) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ChatPantalla(red: red, tel: tel)))
        .then((_) {
      if (mounted) setState(() {});
    });
  }

  void _abrirDiagnostico() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DiagnosticoPantalla(red: red)),
    );
  }

  Future<void> _nuevoContacto() async {
    final nombreCtrl = TextEditingController();
    final telCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nuevo contacto'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nombreCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nombre'),
            ),
            TextField(
              controller: telCtrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Número (10 dígitos)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final tel = limpiarTel(telCtrl.text);
    if (tel.length != 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('El número debe tener 10 dígitos')),
      );
      return;
    }
    if (tel == red.miTel) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ese es tu propio número')),
      );
      return;
    }
    final nombre = nombreCtrl.text.trim();
    red.agregarContacto(tel, nombre.isEmpty ? tel : nombre);
  }

  void _verMiCuenta() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tu cuenta'),
        content: Text('${red.miNombre}\n${red.miTel}'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: red,
      builder: (context, _) {
        final chats = red.chatsOrdenados;
        final n = red.conectados.length;
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Mensajes sin internet'),
                Text(
                  n == 0 ? red.estadoRed : 'Conectado a la red ($n)',
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Estado de conexión',
                onPressed: _abrirDiagnostico,
                icon: const Icon(Icons.cell_tower),
              ),
              IconButton(
                tooltip: 'Tu cuenta',
                onPressed: _verMiCuenta,
                icon: const Icon(Icons.person),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: _nuevoContacto,
            child: const Icon(Icons.person_add),
          ),
          body: chats.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Todavía no tienes chats.\nToca + para agregar un contacto con su número.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  children: [
                    for (final tel in chats) _filaChat(tel),
                    const SizedBox(height: 80),
                  ],
                ),
        );
      },
    );
  }

  Widget _filaChat(String tel) {
    final nombre = red.contactos[tel] ?? tel;
    final ultimo = red.ultimoCon(tel);
    final sinLeer = red.noLeidos[tel] ?? 0;
    return ListTile(
      leading: CircleAvatar(child: Text(nombre.isNotEmpty ? nombre[0].toUpperCase() : '?')),
      title: Text(nombre),
      subtitle: Row(
        children: [
          if (ultimo != null && ultimo.de == red.miTel) ...[
            _IconoEstado(ultimo.estado, tamano: 16),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              ultimo?.texto ?? tel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (ultimo != null) Text(horaTexto(ultimo.hora), style: const TextStyle(fontSize: 12)),
          if (sinLeer > 0)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.green,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('$sinLeer', style: const TextStyle(color: Colors.white, fontSize: 12)),
            ),
        ],
      ),
      onTap: () => _abrirChat(tel),
    );
  }
}

// ---------- Chat con una persona ----------

class ChatPantalla extends StatefulWidget {
  const ChatPantalla({super.key, required this.red, required this.tel});
  final Red red;
  final String tel;

  @override
  State<ChatPantalla> createState() => _ChatPantallaState();
}

class _ChatPantallaState extends State<ChatPantalla> {
  final _ctrl = TextEditingController();
  Red get red => widget.red;

  void _enviar() {
    final texto = _ctrl.text.trim();
    if (texto.isEmpty) return;
    red.enviar(widget.tel, texto);
    _ctrl.clear();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: red,
      builder: (context, _) {
        red.noLeidos.remove(widget.tel); // ya los estás viendo
        final msgs = red.chatCon(widget.tel);
        final nombre = red.contactos[widget.tel] ?? widget.tel;
        final enLinea = red.enLinea(widget.tel);
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(nombre),
                Text(
                  red.estadoDe(widget.tel),
                  style: TextStyle(
                    fontSize: 12,
                    color: enLinea ? Colors.green.shade700 : null,
                    fontWeight: enLinea ? FontWeight.bold : null,
                  ),
                ),
              ],
            ),
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(12),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) {
                    final m = msgs[msgs.length - 1 - i];
                    return _Burbuja(m: m, mio: m.de == red.miTel);
                  },
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _ctrl,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                            hintText: 'Escribe un mensaje',
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _enviar(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(onPressed: _enviar, icon: const Icon(Icons.send)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Burbuja extends StatelessWidget {
  const _Burbuja({required this.m, required this.mio});
  final Mensaje m;
  final bool mio;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    return Align(
      alignment: mio ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 6),
        constraints: const BoxConstraints(maxWidth: 290),
        decoration: BoxDecoration(
          color: mio ? color.primaryContainer : color.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(alignment: Alignment.centerLeft, child: Text(m.texto)),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (m.viaSms) ...[
                  const Text('SMS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 4),
                ],
                Text(horaTexto(m.hora), style: const TextStyle(fontSize: 11)),
                if (mio) ...[
                  const SizedBox(width: 4),
                  _IconoEstado(m.estado),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _IconoEstado extends StatelessWidget {
  const _IconoEstado(this.estado, {this.tamano = 15});
  final Estado estado;
  final double tamano;

  @override
  Widget build(BuildContext context) {
    switch (estado) {
      case Estado.pendiente:
        return Icon(Icons.schedule, size: tamano, color: Colors.grey);
      case Estado.enviado:
        return Icon(Icons.done, size: tamano, color: Colors.grey);
      case Estado.entregado:
        return Icon(Icons.done_all, size: tamano, color: Colors.blue);
    }
  }
}

// ---------- Estado de conexión (diagnóstico) ----------

class DiagnosticoPantalla extends StatefulWidget {
  const DiagnosticoPantalla({super.key, required this.red});
  final Red red;

  @override
  State<DiagnosticoPantalla> createState() => _DiagnosticoPantallaState();
}

class _DiagnosticoPantallaState extends State<DiagnosticoPantalla> {
  Timer? _timer;
  Red get red => widget.red;

  @override
  void initState() {
    super.initState();
    red.actualizarDiagnostico();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => red.actualizarDiagnostico());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Widget _fila(String texto, bool? ok, {String? detalle}) {
    return ListTile(
      dense: true,
      leading: Icon(
        ok == null ? Icons.help_outline : (ok ? Icons.check_circle : Icons.cancel),
        color: ok == null ? Colors.grey : (ok ? Colors.green : Colors.red),
      ),
      title: Text(texto),
      subtitle: detalle == null ? null : Text(detalle),
    );
  }

  Widget _titulo(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(t,
            style: TextStyle(
                fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: red,
      builder: (context, _) {
        final r = red.radios;
        return Scaffold(
          appBar: AppBar(title: const Text('Estado de conexión')),
          body: ListView(
            children: [
              _titulo('Teléfono'),
              _fila('Bluetooth encendido', r['bluetooth']),
              _fila('Wi-Fi encendido', r['wifi'],
                  detalle: 'No necesita internet, solo que esté prendido'),
              _fila('Ubicación (GPS) encendida', r['ubicacion']),
              _fila('Tarjeta SIM lista (para SMS)', r['sim']),
              _fila('Internet', r['internet'], detalle: 'No es necesario'),
              _titulo('Permisos de la app'),
              for (final e in red.permisos.entries)
                _fila(e.key, e.value == 'ok',
                    detalle: e.value == 'bloqueado' ? 'Actívalo en Ajustes de la app' : null),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton(
                  onPressed: openAppSettings,
                  child: const Text('Abrir ajustes de la app'),
                ),
              ),
              _titulo('Red cercana (Bluetooth / Wi-Fi Direct)'),
              _fila('Visible para otros teléfonos', red.anunciando),
              _fila('Buscando otros teléfonos', red.buscando),
              _fila('Teléfonos conectados: ${red.conectados.length}', red.conectados.isNotEmpty),
              for (final v in red.conectados.values)
                ListTile(dense: true, title: Text(v.nombre), subtitle: Text(v.tel)),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: red.reiniciar,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reiniciar conexión'),
                ),
              ),
              SwitchListTile(
                title: const Text('Enviar por SMS si no hay Bluetooth / Wi-Fi'),
                subtitle: const Text('Usa tu señal de celular, no tus datos'),
                value: red.usarSms,
                onChanged: red.cambiarUsarSms,
              ),
              _titulo('Historial'),
              for (final e in red.eventos)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                  child: Text(e, style: const TextStyle(fontSize: 12)),
                ),
              const SizedBox(height: 40),
            ],
          ),
        );
      },
    );
  }
}
