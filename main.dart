// Mensajes sin internet - Fase 1
// Chat entre teléfonos cercanos usando Bluetooth + Wi-Fi Direct (Google Nearby Connections).
// Cada mensaje "salta" de teléfono en teléfono (red mesh) hasta 5 veces.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const MensajesApp());

class MensajesApp extends StatelessWidget {
  const MensajesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mensajes sin internet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
      home: const NombrePantalla(),
    );
  }
}

// ---------- Pantalla 1: el usuario escribe su nombre ----------
class NombrePantalla extends StatefulWidget {
  const NombrePantalla({super.key});

  @override
  State<NombrePantalla> createState() => _NombrePantallaState();
}

class _NombrePantallaState extends State<NombrePantalla> {
  final _ctrl = TextEditingController();

  void _entrar() {
    final nombre = _ctrl.text.trim();
    if (nombre.isEmpty) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => ChatPantalla(nombre: nombre)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.wifi_off, size: 72),
              const SizedBox(height: 16),
              const Text('Mensajes sin internet',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 32),
              TextField(
                controller: _ctrl,
                decoration: const InputDecoration(
                  labelText: 'Tu nombre',
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
    );
  }
}

// ---------- Modelo de mensaje ----------
class Mensaje {
  final String id; // único, para no repetir mensajes en la red
  final String de;
  final String texto;
  final int ttl; // cuántos saltos más puede dar
  final bool mio;

  Mensaje({
    required this.id,
    required this.de,
    required this.texto,
    required this.ttl,
    this.mio = false,
  });

  Map<String, dynamic> toJson() => {'id': id, 'de': de, 'texto': texto, 'ttl': ttl};

  factory Mensaje.fromJson(Map<String, dynamic> j) => Mensaje(
        id: j['id'] as String,
        de: j['de'] as String,
        texto: j['texto'] as String,
        ttl: j['ttl'] as int,
      );

  Mensaje conTtl(int nuevo) => Mensaje(id: id, de: de, texto: texto, ttl: nuevo, mio: mio);
}

// ---------- Pantalla 2: el chat ----------
class ChatPantalla extends StatefulWidget {
  final String nombre;
  const ChatPantalla({super.key, required this.nombre});

  @override
  State<ChatPantalla> createState() => _ChatPantallaState();
}

class _ChatPantallaState extends State<ChatPantalla> {
  static const _servicio = 'com.davy.mensajes_sin_internet';
  static const _saltosMaximos = 5;
  final _strategy = Strategy.P2P_CLUSTER; // permite muchos teléfonos conectados a la vez

  final Map<String, String> _pendientes = {}; // endpointId -> nombre
  final Map<String, String> _conectados = {}; // endpointId -> nombre
  final Set<String> _vistos = {}; // ids de mensajes ya recibidos
  final List<Mensaje> _mensajes = [];
  final _ctrl = TextEditingController();
  String _estado = 'Preparando...';

  @override
  void initState() {
    super.initState();
    _iniciar();
  }

  Future<void> _iniciar() async {
    // 1. Pedir permisos de Bluetooth, Wi-Fi cercano y ubicación
    await [
      Permission.location,
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.nearbyWifiDevices,
    ].request();

    // 2. Anunciarse: "aquí estoy" para que otros me encuentren
    try {
      await Nearby().startAdvertising(
        widget.nombre,
        _strategy,
        onConnectionInitiated: _alIniciarConexion,
        onConnectionResult: _alResultado,
        onDisconnected: _alDesconectar,
        serviceId: _servicio,
      );
    } catch (e) {
      setState(() => _estado = 'Error al anunciar: $e');
    }

    // 3. Buscar a otros teléfonos y conectarse solos
    try {
      await Nearby().startDiscovery(
        widget.nombre,
        _strategy,
        onEndpointFound: (id, nombre, serviceId) {
          if (_conectados.containsKey(id)) return;
          Nearby()
              .requestConnection(
                widget.nombre,
                id,
                onConnectionInitiated: _alIniciarConexion,
                onConnectionResult: _alResultado,
                onDisconnected: _alDesconectar,
              )
              .catchError((_) => false); // si ya se estaba conectando, ignorar
        },
        onEndpointLost: (id) {},
        serviceId: _servicio,
      );
      setState(() => _estado = 'Buscando teléfonos cercanos...');
    } catch (e) {
      setState(() => _estado = 'Error al buscar: $e');
    }
  }

  void _alIniciarConexion(String id, ConnectionInfo info) {
    _pendientes[id] = info.endpointName;
    // Aceptamos automáticamente para que la red crezca sola
    Nearby().acceptConnection(id, onPayLoadRecieved: _alRecibir);
  }

  void _alResultado(String id, Status status) {
    if (status == Status.CONNECTED) {
      setState(() => _conectados[id] = _pendientes[id] ?? 'Desconocido');
    }
    _pendientes.remove(id);
  }

  void _alDesconectar(String id) {
    setState(() => _conectados.remove(id));
  }

  void _alRecibir(String deId, Payload payload) {
    if (payload.type != PayloadType.BYTES || payload.bytes == null) return;
    try {
      final m = Mensaje.fromJson(jsonDecode(utf8.decode(payload.bytes!)));
      if (!_vistos.add(m.id)) return; // ya lo teníamos, no repetir
      setState(() => _mensajes.add(m));
      // RED MESH: pasar el mensaje a los demás teléfonos conectados
      if (m.ttl > 1) _reenviar(m.conTtl(m.ttl - 1), excepto: deId);
    } catch (_) {
      // mensaje dañado, se ignora
    }
  }

  void _reenviar(Mensaje m, {String? excepto}) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(m.toJson())));
    for (final id in _conectados.keys) {
      if (id == excepto) continue;
      Nearby().sendBytesPayload(id, bytes);
    }
  }

  void _enviar() {
    final texto = _ctrl.text.trim();
    if (texto.isEmpty) return;
    final m = Mensaje(
      id: '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1000000)}',
      de: widget.nombre,
      texto: texto,
      ttl: _saltosMaximos,
      mio: true,
    );
    _vistos.add(m.id);
    setState(() => _mensajes.add(m));
    _reenviar(m);
    _ctrl.clear();
  }

  @override
  void dispose() {
    Nearby().stopAdvertising();
    Nearby().stopDiscovery();
    Nearby().stopAllEndpoints();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = _conectados.length;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Chat cercano'),
            Text(
              n == 0 ? _estado : '$n teléfono(s) conectado(s)',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _mensajes.length,
              itemBuilder: (_, i) => _Burbuja(m: _mensajes[i]),
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
  }
}

class _Burbuja extends StatelessWidget {
  final Mensaje m;
  const _Burbuja({required this.m});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    return Align(
      alignment: m.mio ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: m.mio ? color.primaryContainer : color.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!m.mio)
              Text(m.de, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            Text(m.texto),
          ],
        ),
      ),
    );
  }
}
