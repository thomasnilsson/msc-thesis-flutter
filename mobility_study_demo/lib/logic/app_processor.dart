part of app;

class AppProcessor {
  static const int BUFFER_SIZE = 100;
  FileUtil util = FileUtil();
  Geolocator _geoLocator = Geolocator();
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging();

  String uuid;
  Serializer<SingleLocationPoint> _pointSerializer;
  Serializer<Stop> _stopSerializer;
  Serializer<Move> _moveSerializer;
  List<SingleLocationPoint> _pointsBuffer = [];

  int pointsCollectedToday = 0;
  bool streamingLocation = false;
  StreamSubscription<Position> _subscription;
  int numberOfBuffers = 0;

  Future initialize() async {
    await _loadUUID();
    await _initSerializers();
    await _initLocation();
//    await _initNotificationService();
  }

  Future restart() async {
    print('Restarting...');
    if (_subscription != null) {
      _subscription.cancel();
    }

    await _initLocation();
  }

  Future _initNotificationService() async {
    await _firebaseMessaging.requestNotificationPermissions();
    _firebaseMessaging.configure(onMessage: _onMessage);
  }

  Future<dynamic> _onMessage(Map<String, dynamic> message) async {
    print(message);
    return message;
  }

  Future _initSerializers() async {
    File pointsFile = await FileUtil().pointsFile;
    File stopsFile = await FileUtil().stopsFile;
    File movesFile = await FileUtil().movesFile;

    _pointSerializer = Serializer<SingleLocationPoint>(pointsFile, debug: true);
    _stopSerializer = Serializer<Stop>(stopsFile, debug: true);
    _moveSerializer = Serializer<Move>(movesFile, debug: true);
  }

  Future _initLocation() async {
    /// Set a minimum dist of such that we dont track every little move
    /// This is necessary if user is very stationary however, being in bed wont count!
    LocationOptions options = LocationOptions(distanceFilter: 0);
    await _geoLocator.isLocationServiceEnabled().then((response) {
      if (response) {
        streamingLocation = true;
        _subscription = _geoLocator.getPositionStream(options).listen(_onData);
      } else {
        print('Location service not enabled');
      }
    });
  }

  Future<void> _loadUUID() async {
    uuid = await FileUtil().loadUUID();
  }

  /// Loads local data points and filters older points out if needed
  Future<List<SingleLocationPoint>> _loadLocalPoints() async {
    DateTime today = DateTime.now().midnight;
    print('Loading local data points...');
    List<SingleLocationPoint> points = await _pointSerializer.load();
    if (points.isEmpty) {
      return points;
    } else if (points.first.datetime.midnight.isBefore(today)) {
      print('Old location data found, deleting it...');
      points = points.where((p) => p.datetime.midnight == today).toList();
      await _pointSerializer.flush();
      await _pointSerializer.save(points);
    }
    return points;
  }

  void _onData(Position d) async {
    SingleLocationPoint p =
        SingleLocationPoint(Location(d.latitude, d.longitude), d.timestamp);
    _pointsBuffer.add(p);

    print('New location point: $p');

    /// If buffer has reached max capacity, write to file and empty the buffer
    /// This is to avoid constantly reading and writing from file each time a new
    /// point comes in.
    if (_pointsBuffer.length >= BUFFER_SIZE) {
      /// Save buffer locally, empty it, and then upload the points file to firebase
      await _pointSerializer.save(_pointsBuffer);
      _pointsBuffer = [];
      String urlPoints = await FileUtil().uploadPoints(uuid);
      print(urlPoints);

      /// If enough data has been collected, evaluate features
      numberOfBuffers++;
      if (numberOfBuffers >= 5) {
        numberOfBuffers = 0;
        /// Off load to background, i.e. do not AWAIT
        saveAndUpload();
      }
    }
  }

  Future _relay(SendPort sp, List<SingleLocationPoint> points, List<Stop> stops,
      List<Move> moves) {
    ReceivePort receivePort = ReceivePort();
    sp.send([points, stops, moves, receivePort.sendPort]);
    return receivePort.first;
  }

  static void _asyncComputation(SendPort sendPort) async {
    print('Check...!');
    ReceivePort receivePort = ReceivePort();
    sendPort.send(receivePort.sendPort);
    List args = await receivePort.first;

    List<SingleLocationPoint> points = args[0];
    List<Stop> stops = args[1];
    List<Move> moves = args[2];
    SendPort replyPort = args[3];

    DateTime today = DateTime.now().midnight;
    DataPreprocessor preprocessor = DataPreprocessor(today);
    DateTime fourWeeksAgo = today.subtract(Duration(days: 28));
    print('Filering out old stops/moves...');

    /// Filter out stops and moves which were computed today,
    /// which were just loaded as well as stops older than 28 days
    List<Stop> stopsOld = stops.isEmpty
        ? stops
        : stops
            .where((s) =>
                s.arrival.midnight != today.midnight &&
                fourWeeksAgo.leq(s.arrival.midnight))
            .toList();

    List<Move> movesOld = moves.isEmpty
        ? moves
        : moves
            .where((m) =>
                m.stopFrom.arrival.midnight != today.midnight &&
                fourWeeksAgo.leq(m.stopFrom.arrival.midnight))
            .toList();

    print('Calculating new stops...');
    List<Stop> stopsToday =
        points.isEmpty ? [] : preprocessor.findStops(points, filter: false);

    print('Calculating new moves...');
    List<Move> movesToday = stopsToday.isEmpty
        ? []
        : preprocessor.findMoves(points, stopsToday, filter: false);

    /// Get all stop, moves, and places
    List<Stop> stopsAll = stopsOld + stopsToday;
    List<Move> movesAll = movesOld + movesToday;

    print('Calculating new places...');

    List<Place> placesAll = preprocessor.findPlaces(stopsAll);

    print('No. stops: ${stopsAll.length}');
    for (final x in stopsAll) print(x);
    print('No. moves: ${movesAll.length}');
    for (final x in movesAll) print(x);
    print('No. places: ${placesAll.length}');
    for (final x in placesAll) print(x);

    /// Extract features
    Features features = Features(today, stopsAll, placesAll, movesAll);

    /// TODO: Can probably remove this
    features.printOverview();
    print(features.hourMatrixDaily);
    replyPort.send(features);
  }

  /// Feature Calculation
  Future<Features> _calculateFeatures() async {
    /// Load points, stops and moves via package
    print('Reading points');

    print('Reading pointts');
    List<SingleLocationPoint> points = await _loadLocalPoints();

    /// Downsample to make things easier...
//    points = _downSample(points);
    print('Points going into algorithms: ${points.length}');
    pointsCollectedToday = points.length;

    print('Reading stops');
    List<Stop> stopsLoaded = await _stopSerializer.load();

    print('Reading moves');
    List<Move> movesLoaded = await _moveSerializer.load();

    DateTime today = DateTime.now().midnight;
    DataPreprocessor preprocessor = DataPreprocessor(today);
    DateTime fourWeeksAgo = today.subtract(Duration(days: 28));
    print('Filering out old stops/moves...');

    /// Filter out stops and moves which were computed today,
    /// which were just loaded as well as stops older than 28 days
    List<Stop> stopsOld = stopsLoaded.isEmpty
        ? stopsLoaded
        : stopsLoaded
            .where((s) =>
                s.arrival.midnight != today.midnight &&
                fourWeeksAgo.leq(s.arrival.midnight))
            .toList();

    List<Move> movesOld = movesLoaded.isEmpty
        ? movesLoaded
        : movesLoaded
            .where((m) =>
                m.stopFrom.arrival.midnight != today.midnight &&
                fourWeeksAgo.leq(m.stopFrom.arrival.midnight))
            .toList();

    print('Calculating new stops...');
    List<Stop> stopsToday =
        points.isEmpty ? [] : preprocessor.findStops(points, filter: false);

    print('Calculating new moves...');
    List<Move> movesToday = stopsToday.isEmpty
        ? []
        : preprocessor.findMoves(points, stopsToday, filter: false);

    /// Get all stop, moves, and places
    List<Stop> stopsAll = stopsOld + stopsToday;
    List<Move> movesAll = movesOld + movesToday;

    print('No. stops: ${stopsAll.length}');
    print('No. moves: ${movesAll.length}');

    print('Calculating new places...');

    List<Place> placesAll = preprocessor.findPlaces(stopsAll);

    /// Extract features
    Features features = Features(today, stopsAll, placesAll, movesAll);

    /// TODO: Can probably remove this
    features.printOverview();
    print(features.hourMatrixDaily);
    return features;
  }

  Future<void> saveAndUpload() async {
    /// Calculate features, then store stops, move and features
    Features features = await _calculateFeatures();

    await _saveOnDevice(features);

    String urlFeatures = await FileUtil().uploadFeatures(uuid);
    print(urlFeatures);

    String urlPoints = await FileUtil().uploadPoints(uuid);
    print(urlPoints);

    String urlStops = await FileUtil().uploadStops(uuid);
    print(urlStops);

    String urlMoves = await FileUtil().uploadMoves(uuid);
    print(urlMoves);

    print('Saved features');
  }

  Future<void> _saveOnDevice(Features features) async {
    await FileUtil().saveFeatures(features);

    /// Clean up files
    await _stopSerializer.flush();
    await _moveSerializer.flush();

    /// Write updates values
    await _stopSerializer.save(features.stops);
    await _moveSerializer.save(features.moves);
  }
}