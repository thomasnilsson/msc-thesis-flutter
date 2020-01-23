library mobility_features;

import 'package:simple_cluster/src/dbscan.dart';
import 'dart:math';
import 'dataset.dart';
import 'package:stats/stats.dart';

void printList(List l) {
  for (var x in l) print(x);
  print('-' * 50);
}

/// Convert from degrees to radians
double radiansFromDegrees(final double degrees) => degrees * (pi / 180.0);

/// Haversine distance between two points
double haversineDist(List<double> point1, List<double> point2) {
  double lat1 = radiansFromDegrees(point1[0]);
  double lon1 = radiansFromDegrees(point1[1]);
  double lat2 = radiansFromDegrees(point2[0]);
  double lon2 = radiansFromDegrees(point2[1]);

  double earthRadius = 6378137.0; // WGS84 major axis
  double distance = 2 *
      earthRadius *
      asin(sqrt(pow(sin(lat2 - lat1) / 2, 2) +
          cos(lat1) * cos(lat2) * pow(sin(lon2 - lon1) / 2, 2)));

  return distance;
}

class Stop {
  Location location;
  int arrival, departure, placeId;

  Stop(this.location, this.arrival, this.departure, {this.placeId});

  DateTime get arrivalDateTime => DateTime.fromMillisecondsSinceEpoch(arrival);

  DateTime get departureDateTime =>
      DateTime.fromMillisecondsSinceEpoch(departure);

  Duration get duration => Duration(milliseconds: departure - arrival);

  @override
  String toString() {
    String placeString = placeId != null ? placeId.toString() : '<NO PLACE_ID>';
    return 'Stop: ${location.toString()} [$arrivalDateTime - $departureDateTime] ($duration) (PlaceId: $placeString)';
  }
}

class Place {
  int id;
  Location location;
  Duration duration;

  Place(this.id, this.location, this.duration);

  @override
  String toString() {
    return 'Place {$id}:  ${location.toString()} ($duration)';
  }
}

class Move {
  int departure, arrival;
  Location locationFrom, locationTo;
  int placeFromId, placeToId;

  Move(this.locationFrom, this.locationTo, this.placeFromId, this.placeToId,
      this.departure, this.arrival);

  /// The haversine distance between the two places
  double get distance {
    return haversineDist([locationFrom.latitude, locationFrom.longitude],
        [locationTo.latitude, locationTo.longitude]);
  }

  /// The duration of the move in milliseconds
  Duration get duration => Duration(milliseconds: arrival - departure);

  /// The average speed when moving between the two places
  double get meanSpeed => distance / duration.inSeconds.toDouble();

  @override
  String toString() {
    return 'Move: $locationFrom --> $locationTo, (Place ${placeFromId} --> ${placeToId}) ($duration)';
  }
}

/// Preprocessing for the Feature Extraction.
/// Finds Stops, Places and Moves for a day of GPS data
class Preprocessor {
  double minStopDist = 50, minPlaceDist = 50;
  Duration minStopDuration = Duration(minutes: 10),
      minMoveDuration = Duration(minutes: 5);

  Function distf = haversineDist;

  /// Calculate centroid of a gps point cloud
  Location findCentroid(List<Location> data) {
    List<double> lats = data.map((d) => (d.latitude)).toList();
    List<double> lons = data.map((d) => (d.longitude)).toList();

    double medianLat = Stats.fromData(lats).median as double;
    double medianLon = Stats.fromData(lons).median as double;

    return Location(medianLat, medianLon);
  }

  /// Checks if two points are within the minimum distance
  bool isWithinMinDist(Location a, Location b) {
    double d = distf([a.latitude, a.longitude], [b.latitude, b.longitude]);
    return d <= minStopDist;
  }

  /// Find the stops in a sequence of gps data points
  List<Stop> findStops(List<LocationData> data) {
    List<Stop> stops = [];
    int i = 0;
    int j;
    int N = data.length;
    List<LocationData> dataSubset;
    Location centroid;

    /// Go through all the data points
    /// Each iteration looking at a subset of the data set
    while (i < N) {
      j = i + 1;
      dataSubset = data.sublist(i, j);
      centroid = findCentroid(dataSubset.map((d) => (d.location)).toList());

      /// Include a new data point until no longer within radius
      /// to be considered at stop
      /// or when all points have been taken
      while (j < N && isWithinMinDist(data[j].location, centroid)) {
        j += 1;
        dataSubset = data.sublist(i, j);
        centroid = findCentroid(dataSubset.map((d) => (d.location)).toList());
      }

      /// The centroid of the biggest subset is the location of the found stop
      Stop s = Stop(centroid, dataSubset.first.time, dataSubset.last.time);
      stops.add(s);

      /// Update i, such that we no longer look at
      /// the previously considered data points
      i = j;
    }

    /// Filter out stops which are shorter than the min. duration
    return stops.where((s) => (s.duration >= minStopDuration)).toList();
  }

  /// Finds the places by clustering stops with the DBSCAN algorithm
  List<Place> findPlaces(List<Stop> stops) {
    List<Place> places = [];

    DBSCAN dbscan = DBSCAN(
        epsilon: minPlaceDist, minPoints: 1, distanceMeasure: haversineDist);

    /// Extract gps coordinates from stops
    List<List<double>> gpsCoords = stops
        .map((s) => ([s.location.latitude, s.location.longitude]))
        .toList();

    /// Run DBSCAN on data points
    dbscan.run(gpsCoords);

    /// Extract labels for each stop, each label being a cluster
    /// Filter out stops labelled as noise (where label is -1)
    Set<int> clusterLabels = dbscan.label.where((l) => (l != -1)).toSet();

    for (int label in clusterLabels) {
      /// Get indices of all stops with the current cluster label
      List<int> indices =
          stops.asMap().keys.where((i) => (dbscan.label[i] == label)).toList();

      /// For each index, get the corresponding stop
      List<Stop> stopsForPlace = indices.map((i) => (stops[i])).toList();

      /// Given all stops belonging to a place,
      /// calculate the centroid of the place
      List<Location> stopsLocations =
          stopsForPlace.map((x) => (x.location)).toList();
      Location centroid = findCentroid(stopsLocations);

      /// Calculate the sum of the durations spent at the stops,
      /// belonging to the place
      Duration duration =
          stopsForPlace.map((s) => (s.duration)).reduce((a, b) => a + b);

      /// Add place to the list
      Place p = Place(label, centroid, duration);
      places.add(p);

      /// Set placeId field for the stops belonging to this place
      stopsForPlace.forEach((s) => s.placeId = p.id);
    }
    return places;
  }

  List<Move> findMoves(List<LocationData> data, List<Stop> stops) {
    List<Move> moves = [];
    int departure = data.map((d) => (d.time)).reduce(min);
    int arrival;

    /// Non-existent starting stop
    int prevPlaceId = -1;

    for (Stop stop in stops) {
      /// Check for moves between this and the next stop
      List<LocationData> locationPoints = data
          .where((d) => (d.time >= departure && d.time <= stop.arrival))
          .toList();

      /// We have moves between stop[i] and stop[i+1]
      if (locationPoints.isNotEmpty) {
        arrival = stop.arrival;

        moves.add(Move(
            locationPoints.first.location,
            locationPoints.last.location,
            prevPlaceId,
            stop.placeId,
            departure,
            stop.arrival));

        departure = stop.departure;
        prevPlaceId = stop.placeId;
      }

      /// Otherwise, if there is a 'dead end' i.e.
      /// no moves between stop[i] and stop[i+1]
      else {
        /// Check for moves after the current stop
        locationPoints = data.where((d) => (d.time >= departure)).toList();

        /// We have moves after stop[i]
        if (locationPoints.isNotEmpty) {
          arrival = locationPoints.map((d) => (d.time)).reduce(max);

          /// Set -1 as the place_id for the move, since it
          /// has a 'dead end' i.e. the stop would be considered noise by DBSCAN
          moves.add(Move(
              locationPoints.first.location,
              locationPoints.last.location,
              prevPlaceId,
              -1,
              departure,
              arrival));
        }
      }
    }

    /// Filter out moves that are too short according to the criterion
    return moves.where((m) => (m.duration >= minMoveDuration)).toList();
  }
}
