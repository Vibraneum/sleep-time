import 'package:sqflite/sqflite.dart';
// ignore: depend_on_referenced_packages
import 'package:path/path.dart' as p;

/// Memory types mirroring Concierge's memory system.
enum MemoryType { goal, mood, constraint, preference, openLoop, negotiation }

class MemoryItem {
  final int? id;
  final MemoryType type;
  final String text;
  final double confidence;
  final DateTime createdAt;
  final DateTime? expiresAt;

  MemoryItem({
    this.id,
    required this.type,
    required this.text,
    this.confidence = 0.7,
    DateTime? createdAt,
    this.expiresAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'type': type.name,
        'text': text,
        'confidence': confidence,
        'created_at': createdAt.toIso8601String(),
        'expires_at': expiresAt?.toIso8601String(),
      };

  factory MemoryItem.fromMap(Map<String, dynamic> map) => MemoryItem(
        id: map['id'] as int?,
        type: MemoryType.values.firstWhere((e) => e.name == map['type']),
        text: map['text'] as String,
        confidence: (map['confidence'] as num?)?.toDouble() ?? 0.7,
        createdAt: DateTime.parse(map['created_at'] as String),
        expiresAt: map['expires_at'] != null
            ? DateTime.parse(map['expires_at'] as String)
            : null,
      );
}

class NegotiationRecord {
  final int? id;
  final DateTime timestamp;
  final String userReason;
  final bool granted;
  final int minutesGranted;
  final String guardianResponse;
  final int grantNumber; // 1st, 2nd, 3rd attempt that session

  NegotiationRecord({
    this.id,
    DateTime? timestamp,
    required this.userReason,
    required this.granted,
    this.minutesGranted = 0,
    required this.guardianResponse,
    this.grantNumber = 0,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'timestamp': timestamp.toIso8601String(),
        'user_reason': userReason,
        'granted': granted ? 1 : 0,
        'minutes_granted': minutesGranted,
        'guardian_response': guardianResponse,
        'grant_number': grantNumber,
      };

  factory NegotiationRecord.fromMap(Map<String, dynamic> map) =>
      NegotiationRecord(
        id: map['id'] as int?,
        timestamp: DateTime.parse(map['timestamp'] as String),
        userReason: map['user_reason'] as String,
        granted: (map['granted'] as int) == 1,
        minutesGranted: map['minutes_granted'] as int? ?? 0,
        guardianResponse: map['guardian_response'] as String,
        grantNumber: map['grant_number'] as int? ?? 0,
      );
}

class ConversationMessage {
  final int? id;
  final String role; // 'user' or 'guardian'
  final String content;
  final DateTime timestamp;
  final String sessionId;

  ConversationMessage({
    this.id,
    required this.role,
    required this.content,
    DateTime? timestamp,
    required this.sessionId,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'role': role,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
        'session_id': sessionId,
      };

  factory ConversationMessage.fromMap(Map<String, dynamic> map) =>
      ConversationMessage(
        id: map['id'] as int?,
        role: map['role'] as String,
        content: map['content'] as String,
        timestamp: DateTime.parse(map['timestamp'] as String),
        sessionId: map['session_id'] as String,
      );
}

class MemoryService {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dbPath, 'sleep_guardian.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE memories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            text TEXT NOT NULL,
            confidence REAL DEFAULT 0.7,
            created_at TEXT NOT NULL,
            expires_at TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE negotiations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            user_reason TEXT NOT NULL,
            granted INTEGER NOT NULL DEFAULT 0,
            minutes_granted INTEGER DEFAULT 0,
            guardian_response TEXT NOT NULL,
            grant_number INTEGER DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE conversations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            session_id TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE sleep_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date TEXT NOT NULL,
            lockdown_start TEXT NOT NULL,
            actual_sleep TEXT,
            grants_used INTEGER DEFAULT 0,
            total_extra_minutes INTEGER DEFAULT 0,
            compliance_score REAL DEFAULT 1.0
          )
        ''');
      },
    );
    return _db!;
  }

  // --- Memories ---

  static Future<void> saveMemory(MemoryItem item) async {
    final db = await database;
    await db.insert('memories', item.toMap());
  }

  static Future<List<MemoryItem>> getMemories({
    MemoryType? type,
    int limit = 20,
  }) async {
    final db = await database;
    final where = type != null ? 'type = ?' : null;
    final whereArgs = type != null ? [type.name] : null;
    final rows = await db.query(
      'memories',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(MemoryItem.fromMap).toList();
  }

  static Future<List<MemoryItem>> getActiveMemories() async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final rows = await db.query(
      'memories',
      where: 'expires_at IS NULL OR expires_at > ?',
      whereArgs: [now],
      orderBy: 'created_at DESC',
      limit: 50,
    );
    return rows.map(MemoryItem.fromMap).toList();
  }

  // --- Negotiations ---

  static Future<void> saveNegotiation(NegotiationRecord record) async {
    final db = await database;
    await db.insert('negotiations', record.toMap());
  }

  static Future<List<NegotiationRecord>> getRecentNegotiations({
    int days = 7,
    int limit = 20,
  }) async {
    final db = await database;
    final since =
        DateTime.now().subtract(Duration(days: days)).toIso8601String();
    final rows = await db.query(
      'negotiations',
      where: 'timestamp > ?',
      whereArgs: [since],
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return rows.map(NegotiationRecord.fromMap).toList();
  }

  static Future<int> getTonightGrantCount() async {
    final db = await database;
    final tonight = DateTime.now().copyWith(hour: 22, minute: 0, second: 0);
    final rows = await db.query(
      'negotiations',
      where: 'timestamp > ? AND granted = 1',
      whereArgs: [tonight.toIso8601String()],
    );
    return rows.length;
  }

  // --- Conversations ---

  static Future<void> saveMessage(ConversationMessage msg) async {
    final db = await database;
    await db.insert('conversations', msg.toMap());
  }

  static Future<List<ConversationMessage>> getSessionMessages(
    String sessionId, {
    int limit = 50,
  }) async {
    final db = await database;
    final rows = await db.query(
      'conversations',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'timestamp ASC',
      limit: limit,
    );
    return rows.map(ConversationMessage.fromMap).toList();
  }

  // --- Sleep Log ---

  static Future<void> logSleep({
    required DateTime lockdownStart,
    DateTime? actualSleep,
    int grantsUsed = 0,
    int totalExtraMinutes = 0,
  }) async {
    final db = await database;
    final date = lockdownStart.toIso8601String().split('T')[0];
    final existing = await db.query(
      'sleep_log',
      columns: ['id'],
      where: 'date = ?',
      whereArgs: [date],
      limit: 1,
    );
    if (existing.isNotEmpty) return;

    final compliance = grantsUsed == 0 ? 1.0 : (1.0 - (grantsUsed * 0.2));
    await db.insert('sleep_log', {
      'date': date,
      'lockdown_start': lockdownStart.toIso8601String(),
      'actual_sleep': actualSleep?.toIso8601String(),
      'grants_used': grantsUsed,
      'total_extra_minutes': totalExtraMinutes,
      'compliance_score': compliance.clamp(0.0, 1.0),
    });
  }

  static Future<List<Map<String, dynamic>>> getRecentSleepLog({
    int days = 14,
  }) async {
    final db = await database;
    final since =
        DateTime.now().subtract(Duration(days: days)).toIso8601String();
    return db.query(
      'sleep_log',
      where: 'date > ?',
      whereArgs: [since.split('T')[0]],
      orderBy: 'date DESC',
    );
  }

  static Future<double> getComplianceRate({int days = 7}) async {
    final logs = await getRecentSleepLog(days: days);
    if (logs.isEmpty) return 1.0;
    final total = logs.fold<double>(
      0.0,
      (sum, log) => sum + (log['compliance_score'] as double? ?? 1.0),
    );
    return total / logs.length;
  }

  /// Build a context string for the LLM about the user's negotiation history.
  static Future<String> buildNegotiationContext() async {
    final negotiations = await getRecentNegotiations(days: 7);
    final compliance = await getComplianceRate();
    final tonightGrants = await getTonightGrantCount();
    final memories = await getActiveMemories();

    final buf = StringBuffer();
    buf.writeln('== YOUR MEMORY ==\n');

    buf.writeln(
      'compliance rate (7 days): ${(compliance * 100).toStringAsFixed(0)}%',
    );
    buf.writeln('grants used tonight: $tonightGrants');
    buf.writeln('');

    if (negotiations.isNotEmpty) {
      buf.writeln('recent negotiations:');
      for (final n in negotiations.take(10)) {
        final date = n.timestamp.toIso8601String().split('T')[0];
        final time =
            '${n.timestamp.hour.toString().padLeft(2, '0')}:${n.timestamp.minute.toString().padLeft(2, '0')}';
        final result = n.granted ? 'GRANTED ${n.minutesGranted}min' : 'DENIED';
        buf.writeln('- $date $time: "${n.userReason}" → $result');
      }
      buf.writeln('');
    }

    final activeMemories =
        memories.where((m) => m.type != MemoryType.negotiation).toList();
    if (activeMemories.isNotEmpty) {
      buf.writeln('what you know about this user:');
      for (final m in activeMemories.take(12)) {
        buf.writeln('- [${m.type.name}] ${m.text}');
      }
    }

    return buf.toString();
  }
}
