// Mensajes sin internet - Versión 2
// - Registro con nombre y número de celular
// - Contactos y chats privados (cada quien ve solo sus mensajes)
// - Hora en cada mensaje y estado: 🕓 pendiente, ✓ enviado, ✓✓ entregado
// - Red mesh por Bluetooth + Wi-Fi Direct (Google Nearby Connections)
// - Los mensajes se guardan en el teléfono

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(MensajesApp(red: Red(prefs)));
}

// ---------- Utilidades ----------

/// Deja solo los últimos 10 dígitos del número.
String limpiarTel(String t) {
  final d = t.replaceAll(RegExp(r'\D'), '');
  return d.length > 10 ? d.substring(d.length - 10) : d;
}

/// Hora estilo "9:17 p.m." (y la fecha si no es de hoy).
String horaTexto(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final mm = d.minute.toString().padLeft(2, '0');
  final ampm = d.hour < 12 ? 'a.m.' : 'p.m.';
  final hoy = DateTime.now();
  final esHoy = d.year == hoy.year && d.month == hoy.month && d.day == hoy.day;
  final fecha = esHoy ? '' : '${d.day}/${d.month} ';
  return '$fecha$h12:$mm $ampm';
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
  });

  final String id;
  final String de; // número de quien lo escribió
  final String deNombre;
  final String para; // número de quien lo recibe
  final String texto;
  final int hora; // cuándo se escribió (milisegundos)
  Estado estado;

  Map<String, dynamic> toJson() => {
        'id': id,
        'de': de,
        'deNombre': deNombre,
        'para': para,
        'texto': texto,
        'hora': hora,
        'estado': estado.index,
      };

  factory Mensaje.fromJson(Map<String, dynamic> j) => Mensaje(
        id: j['id'] as String,
        de: j['de'] as String,
        deNombre: (j['deNombre'] ?? '') as String,
        para: j['para'] as String,
        texto: j['texto'] as String,
        hora: j['hora'] as int,
        estado: Estado.values[(j['estado'] ?? 0) as int],
      );

  /// Lo que viaja por la red.
  Map<String, dynamic> paquete(int ttl) => {
        't': 'msg',
        'id': id,
        'de': de,
        'deNombre': deNombre,
        'para': para,
        'texto': texto,
        'hora': hora,
        'ttl': ttl,
      };
}

class Vecino {
  Vecino(this.nombre, this.tel);
  final String nombre;
  final String tel;
}

// ---------- La red (toda la lógica) ----------

class Red extends ChangeNotifier {
  Red(this._prefs) {
    miNombre = _prefs.getString('yo_nombre') ?? '';
    miTel = _prefs.getString('yo_tel') ?? '';
    final c = _prefs.getString('contactos');
    if (c != null) {
      (jsonDecode(c) as Map<String, dynamic>)
          .forEach((tel, nombre) => contactos[tel] = nombre as String);
    }
    final m = _prefs.getString('mensajes');
    if (m != null) {
      for (final x in jsonDecode(m) as List) {
        final msg = Mensaje.fromJson(Map<String, dynamic>.from(x as Map));
        mensajes.add(msg);
        _vistos.add(msg.id);
      }
    }
  }

  static const _servicio = 'com.davy.mensajes_sin_internet';
  static const _saltos = 5; // cuántas veces puede saltar un mensaje
  final _strategy = Strategy.P2P_CLUSTER;
  final SharedPreferences _prefs;

  String miNombre = '';
  String miTel = '';
  final Map<String, String> contactos = {}; // número -> nombre
  final List<Mensaje> mensajes = [];
  final Map<String, int> noLeidos = {}; // número -> cuántos sin leer
  final Map<String, Vecino> conectados = {}; // endpointId -> vecino
  String estadoRed = 'Preparando...';

  final Map<String, Vecino> _porConectar = {};
  final Set<String> _conectando = {};
  final Map<String, int> _intentos = {};
  final Set<String> _vistos = {};
  bool _iniciada = false;

  bool get registrado => miTel.isNotEmpty;
  String get _miEndpoint => '$miNombre|$miTel';

  bool estaCerca(String tel) => conectados.values.any((v) => v.tel == tel);

  List<Vecino> get cerca => conectados.values.where((v) => v.tel.isNotEmpty).toList();

  List<Mensaje> chatCon(String tel) => mensajes
      .where((m) => (m.de == miTel && m.para == tel) || (m.de == tel && m.para == miTel))
      .toList();

  Mensaje? ultimoCon(String tel) {
    final l = chatCon(tel);
    return l.isEmpty ? null : l.last;
  }

  /// Contactos ordenados: el chat más reciente primero.
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

  void _guardar() {
    _prefs.setString('contactos', jsonEncode(contactos));
    _prefs.setString('mensajes', jsonEncode(mensajes.map((m) => m.toJson()).toList()));
  }

  void _estado(String s) {
    estadoRed = s;
    notifyListeners();
  }

  String _nuevoId() =>
      '$miTel-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1000000)}';

  Vecino _vecinoDe(String endpointName) {
    final i = endpointName.lastIndexOf('|');
    if (i < 0) return Vecino(endpointName, '');
    return Vecino(endpointName.substring(0, i), endpointName.substring(i + 1));
  }

  // ----- Encender Bluetooth/Wi-Fi y buscar teléfonos -----

  Future<void> iniciar() async {
    if (_iniciada) return;
    _iniciada = true;

    await [
      Permission.location,
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.nearbyWifiDevices,
    ].request();

    final gps = await Permission.location.serviceStatus;
    final gpsApagado = gps != ServiceStatus.enabled;

    try {
      await Nearby().startAdvertising(
        _miEndpoint,
        _strategy,
        onConnectionInitiated: _alIniciar,
        onConnectionResult: _alResultado,
        onDisconnected: _alDesconectar,
        serviceId: _servicio,
      );
    } catch (e) {
      _estado('Error al anunciar: $e');
      return;
    }

    try {
      await Nearby().startDiscovery(
        _miEndpoint,
        _strategy,
        onEndpointFound: _alEncontrar,
        onEndpointLost: (id) {},
        serviceId: _servicio,
      );
    } catch (e) {
      _estado('Error al buscar: $e');
      return;
    }

    _estado(gpsApagado
        ? '⚠️ Enciende la Ubicación (GPS) y vuelve a abrir la app'
        : 'Buscando teléfonos cercanos...');
  }

  void _alEncontrar(String id, String endpointName, String serviceId) {
    if (conectados.containsKey(id) || _conectando.contains(id)) return;
    final v = _vecinoDe(endpointName);
    _estado('Encontré a ${v.nombre}, conectando...');
    // Para que los dos teléfonos no se pidan conexión al mismo tiempo,
    // la pide primero el del número menor. El otro espera y, si no pasa nada, la pide él.
    if (miTel.compareTo(v.tel) < 0) {
      _pedirConexion(id);
    } else {
      Timer(const Duration(seconds: 8), () => _pedirConexion(id));
    }
  }

  void _pedirConexion(String id) {
    if (conectados.containsKey(id) || _conectando.contains(id)) return;
    final intentos = (_intentos[id] ?? 0) + 1;
    if (intentos > 3) return;
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
      _estado('No se pudo conectar ($e). Reintentando...');
      Timer(const Duration(seconds: 5), () => _pedirConexion(id));
      return false;
    });
  }

  void _alIniciar(String id, ConnectionInfo info) {
    _conectando.add(id);
    _porConectar[id] = _vecinoDe(info.endpointName);
    // Aceptamos solos para que la red crezca sin preguntar
    Nearby().acceptConnection(id, onPayLoadRecieved: _alRecibir).catchError((Object e) => false);
  }

  void _alResultado(String id, Status status) {
    _conectando.remove(id);
    final v = _porConectar.remove(id);
    if (status == Status.CONNECTED && v != null) {
      conectados[id] = v;
      _intentos.remove(id);
      _estado('Conectado con ${v.nombre}');
      _reenviarPendientes();
    } else {
      _estado('La conexión falló. Reintentando...');
      Timer(const Duration(seconds: 5), () => _pedirConexion(id));
    }
  }

  void _alDesconectar(String id) {
    final v = conectados.remove(id);
    _estado(conectados.isEmpty
        ? 'Buscando teléfonos cercanos...'
        : '${v?.nombre ?? 'Alguien'} se desconectó');
  }

  // ----- Enviar y recibir -----

  void enviar(String para, String texto) {
    final m = Mensaje(
      id: _nuevoId(),
      de: miTel,
      deNombre: miNombre,
      para: para,
      texto: texto,
      hora: DateTime.now().millisecondsSinceEpoch,
    );
    _vistos.add(m.id);
    mensajes.add(m);
    _mandar(m);
    _guardar();
    notifyListeners();
  }

  void _mandar(Mensaje m) {
    if (conectados.isEmpty) return; // se queda 🕓 pendiente hasta que haya alguien cerca
    _difundir(m.paquete(_saltos));
    if (m.estado == Estado.pendiente) m.estado = Estado.enviado;
  }

  /// Cuando se conecta alguien nuevo, volvemos a mandar lo que no ha llegado.
  void _reenviarPendientes() {
    for (final m in mensajes) {
      if (m.de == miTel && m.estado != Estado.entregado) _mandar(m);
    }
    _guardar();
    notifyListeners();
  }

  void _difundir(Map<String, dynamic> paquete, {String? excepto}) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(paquete)));
    for (final id in conectados.keys.toList()) {
      if (id == excepto) continue;
      Nearby().sendBytesPayload(id, bytes).catchError((Object _) {});
    }
  }

  void _enviarAcuse(String msgId, String para) {
    final id = _nuevoId();
    _vistos.add(id);
    _difundir({'t': 'ack', 'id': id, 'msgId': msgId, 'de': miTel, 'para': para, 'ttl': _saltos});
  }

  void _alRecibir(String endpointId, Payload payload) {
    if (payload.type != PayloadType.BYTES || payload.bytes == null) return;
    Map<String, dynamic> j;
    try {
      j = Map<String, dynamic>.from(jsonDecode(utf8.decode(payload.bytes!)) as Map);
    } catch (_) {
      return; // paquete dañado
    }

    final tipo = j['t'] as String?;
    final id = j['id'] as String?;
    final para = j['para'] as String?;
    final ttl = (j['ttl'] as int?) ?? 0;
    if (tipo == null || id == null || para == null) return;
    final esNuevo = _vistos.add(id);

    // ¿Es para mí?
    if (para == miTel) {
      if (tipo == 'msg') {
        final de = j['de'] as String;
        if (esNuevo && !mensajes.any((m) => m.id == id)) {
          final deNombre = (j['deNombre'] ?? de) as String;
          mensajes.add(Mensaje(
            id: id,
            de: de,
            deNombre: deNombre,
            para: para,
            texto: j['texto'] as String,
            hora: j['hora'] as int,
            estado: Estado.entregado,
          ));
          contactos.putIfAbsent(de, () => deNombre);
          noLeidos[de] = (noLeidos[de] ?? 0) + 1;
          _guardar();
          notifyListeners();
        }
        // Siempre avisamos que llegó (por si el aviso anterior se perdió)
        _enviarAcuse(id, de);
      } else if (tipo == 'ack') {
        final msgId = j['msgId'] as String?;
        for (final m in mensajes) {
          if (m.id == msgId && m.de == miTel && m.estado != Estado.entregado) {
            m.estado = Estado.entregado;
            _guardar();
            notifyListeners();
          }
        }
      }
      return;
    }

    // No es para mí: lo paso a los demás (red mesh), sin mostrarlo
    if (!esNuevo) return;
    if (ttl > 1) {
      j['ttl'] = ttl - 1;
      _difundir(j, excepto: endpointId);
    }
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

// ---------- Pantalla 1: registro ----------

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

// ---------- Pantalla 2: contactos y chats ----------

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

  void _abrirChat(String tel, {String? nombre}) {
    if (!red.contactos.containsKey(tel)) red.agregarContacto(tel, nombre ?? tel);
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ChatPantalla(red: red, tel: tel)))
        .then((_) {
      if (mounted) setState(() {}); // actualiza los "no leídos" al regresar
    });
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
    final nombre = nombreCtrl.text.trim();
    red.agregarContacto(tel, nombre.isEmpty ? tel : nombre);
  }

  void _verMiNumero() {
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
        final cerca = red.cerca;
        final chats = red.chatsOrdenados;
        final n = red.conectados.length;
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Mensajes sin internet'),
                Text(
                  n == 0 ? red.estadoRed : '$n teléfono(s) conectado(s)',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
            actions: [
              IconButton(onPressed: _verMiNumero, icon: const Icon(Icons.person)),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: _nuevoContacto,
            child: const Icon(Icons.person_add),
          ),
          body: ListView(
            children: [
              if (cerca.isNotEmpty) ...[
                const _Titulo('Cerca de ti'),
                for (final v in cerca)
                  ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: Colors.green,
                      child: Icon(Icons.bluetooth_connected, color: Colors.white),
                    ),
                    title: Text(red.contactos[v.tel] ?? v.nombre),
                    subtitle: Text(v.tel),
                    onTap: () => _abrirChat(v.tel, nombre: v.nombre),
                  ),
              ],
              const _Titulo('Chats'),
              if (chats.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Todavía no tienes chats.\nToca + para agregar un contacto con su número.',
                    textAlign: TextAlign.center,
                  ),
                ),
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

class _Titulo extends StatelessWidget {
  const _Titulo(this.texto);
  final String texto;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        texto,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

// ---------- Pantalla 3: chat con una persona ----------

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
        final cerca = red.estaCerca(widget.tel);
        final nombre = red.contactos[widget.tel] ?? widget.tel;
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(nombre),
                Text(
                  cerca ? 'Cerca de ti' : widget.tel,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          body: Column(
            children: [
              if (!cerca)
                Container(
                  width: double.infinity,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  padding: const EdgeInsets.all(8),
                  child: const Text(
                    'No está conectado directo contigo. Tus mensajes saltan por otros teléfonos '
                    'cercanos o se envían cuando haya alguien cerca.',
                    style: TextStyle(fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),
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
