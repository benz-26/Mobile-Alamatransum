import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_maps_webservice/directions.dart' as directions;

void main() {
  runApp(MyApp());
}

class Station {
  final String name;
  final double latitude;
  final double longitude;
  final String type;

  Station({
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.type,
  });

  factory Station.fromJson(Map<String, dynamic> json) {
    return Station(
      name: json['name'] ?? 'Unknown',
      latitude: (json['latitude'] ?? 0.0).toDouble(),
      longitude: (json['longitude'] ?? 0.0).toDouble(),
      type: json['type'] ?? 'Unknown',
    );
  }
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Alamatrain',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  late List<Station> stations = [];
  late List<String> types = [];
  String? selectedType;
  Station? selectedStation;
  Timer? _timer;
  double _estimatedTime = 0.0; // Estimated time to reach the destination in minutes
  Position? _currentPosition;
  Completer<GoogleMapController> _controller = Completer();
  Set<Polyline> _polylines = {};
  final String apiKey = 'YOUR_GMAPS_API_HERE';
  bool _isLoading = true;
  bool _isError = false;
  bool _notifiedProximity = false;

  @override
  void initState() {
    super.initState();
    initializeNotification();
    fetchStations();
    _getCurrentLocation();
  }

  void initializeNotification() {
    const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
    final InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
    flutterLocalNotificationsPlugin.initialize(initializationSettings);
  }

  Future<void> fetchStations() async {
    try {
      final response = await http.get(Uri.parse('http://10.0.2.2:8080/stations'));

      if (response.statusCode == 200) {
        List<dynamic> data = jsonDecode(response.body);
        setState(() {
          stations = data.map((station) => Station.fromJson(station)).toList();
          types = stations.map((station) => station.type).toSet().toList();
        });
      } else {
        throw Exception('Failed to load stations');
      }
    } catch (e) {
      setState(() {
        _isError = true;
      });
      print('Error fetching stations: $e');
    }
  }

  void saveDestination() {
    if (selectedStation != null) {
      print('Destination saved: ${selectedStation!.name}');
      _timer?.cancel();
      _timer = Timer.periodic(Duration(seconds: 10), (timer) {
        _getCurrentLocation();
        if (_currentPosition != null && selectedStation != null) {
          _calculateDistanceAndTime();
        }
      });
    } else {
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: Text('Error'),
            content: Text('Please select a destination station.'),
            actions: <Widget>[
              TextButton(
                child: Text('OK'),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
            ],
          );
        },
      );
    }
  }

  void showProximityNotification() async {
    const AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'proximity_channel_id',
      'Proximity Notifications',
      'Notification when within 200 meters of destination',
      importance: Importance.max,
      priority: Priority.high,
      sound: RawResourceAndroidNotificationSound('proximity_alert'),
    );

    const NotificationDetails platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);

    await flutterLocalNotificationsPlugin.show(
      1,
      'Proximity Alert',
      'You are 200 meters away from your destination (${selectedStation!.name})',
      platformChannelSpecifics,
      payload: 'proximity_alert',
    );
  }

  void showArrivalNotification() async {
    const AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'arrival_channel_id',
      'Arrival Notifications',
      'Notification when arriving at destination',
      importance: Importance.max,
      priority: Priority.high,
      sound: RawResourceAndroidNotificationSound('arrival_alert'),
    );

    const NotificationDetails platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);

    await flutterLocalNotificationsPlugin.show(
      2,
      'Arrival Alert',
      'You have arrived at your destination (${selectedStation!.name})',
      platformChannelSpecifics,
      payload: 'arrival_alert',
    );
  }

  void _getCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    // Test if location services are enabled.
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      // Location services are not enabled, so return.
      setState(() {
        _isLoading = false;
        _isError = true;
      });
      return Future.error('Location services are disabled.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        // Permissions are denied, next time you could try requesting permissions again
        // (this also prompts the user to go to the settings and enable permissions).
        setState(() {
          _isLoading = false;
          _isError = true;
        });
        return Future.error('Location permissions are denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      // Permissions are denied forever, handle appropriately.
      setState(() {
        _isLoading = false;
        _isError = true;
      });
      return Future.error(
          'Location permissions are permanently denied, we cannot request permissions.');
    }

    try {
      final position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      setState(() {
        _currentPosition = position;
        _isLoading = false;
      });
      _moveCameraToCurrentPosition();
    } catch (e) {
      setState(() {
        _isLoading = false;
        _isError = true;
      });
      print('Error getting current location: $e');
    }
  }

  Future<void> _moveCameraToCurrentPosition() async {
    if (_currentPosition != null) {
      final GoogleMapController controller = await _controller.future;
      controller.animateCamera(CameraUpdate.newCameraPosition(
        CameraPosition(target: LatLng(_currentPosition!.latitude, _currentPosition!.longitude), zoom: 14),
      ));
    }
  }

  Future<void> _calculateDistanceAndTime() async {
    final directions.GoogleMapsDirections directionsService = directions.GoogleMapsDirections(apiKey: apiKey);
    final directions.Location origin = directions.Location(lat: _currentPosition!.latitude, lng: _currentPosition!.longitude);
    final directions.Location destination = directions.Location(lat: selectedStation!.latitude, lng: selectedStation!.longitude);

    final directions.DirectionsResponse result = await directionsService.directionsWithLocation(
      origin,
      destination,
    );

    if (result.isOkay) {
      final directions.Route route = result.routes.first;
      final directions.Leg leg = route.legs.first;
      final distance = leg.distance?.value ?? 0; // Distance in meters
      final duration = leg.duration?.value ?? 0; // Duration in seconds

      setState(() {
        _estimatedTime = duration / 60.0; // Convert seconds to minutes
      });

      _drawPolyline(route);

      if (distance < 200 && !_notifiedProximity) {
        showProximityNotification();
        _notifiedProximity = true;
      }

      if (distance < 100) { // Consider the arrival if the distance is less than 100 meters
        showArrivalNotification();
        _timer?.cancel();
      }
    } else {
      print('Error: ${result.errorMessage}');
    }
  }

  void _drawPolyline(directions.Route route) {
    final points = decodePolyline(route.overviewPolyline.points);
    setState(() {
      _polylines.add(
        Polyline(
          polylineId: PolylineId('route'),
          points: points,
          color: Colors.blue,
          width: 5,
        ),
      );
    });
  }

  List<LatLng> decodePolyline(String encoded) {
    List<LatLng> poly = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      poly.add(LatLng(lat / 1E5, lng / 1E5));
    }

    return poly;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: Text('Alamatrain'),
        ),
        body: _isLoading
            ? Center(child: CircularProgressIndicator())
            : _isError
            ? Center(child: Text('Error loading data'))
            : stations.isNotEmpty
            ? Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.all(16.0),
              child: Container(
                padding: EdgeInsets.all(16.0),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: EdgeInsets.all(16.0),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        children: [
                          Center(
                            child: Text(
                              'Current Location',
                              style: TextStyle(color: Colors.white, fontSize: 18),
                            ),
                          ),
                          SizedBox(height: 10),
                          if (_currentPosition != null)
                            Text(
                              'Lat: ${_currentPosition!.latitude}, Lng: ${_currentPosition!.longitude}',
                              style: TextStyle(color: Colors.white),
                            ),
                        ],
                      ),
                    ),
                    SizedBox(height: 10),
                    DropdownButton<String>(
                      hint: Text('Select Type'),
                      value: selectedType,
                      onChanged: (String? newValue) {
                        setState(() {
                          selectedType = newValue;
                          selectedStation = null;
                        });
                      },
                      items: types.map((String type) {
                        return DropdownMenuItem<String>(
                          value: type,
                          child: Text(type),
                        );
                      }).toList(),
                    ),
                    SizedBox(height: 10),
                    DropdownButton<Station>(
                      hint: Text('Select Station'),
                      value: selectedStation,
                      onChanged: (Station? newValue) {
                        setState(() {
                          selectedStation = newValue;
                        });
                      },
                      items: stations
                          .where((station) => station.type == selectedType)
                          .map((Station station) {
                        return DropdownMenuItem<Station>(
                          value: station,
                          child: Text(station.name),
                        );
                      }).toList(),
                    ),
                    SizedBox(height: 10),
                    ElevatedButton(
                      onPressed: saveDestination,
                      child: Text('Select Location'),
                    ),
                    SizedBox(height: 10),
                    Container(
                      padding: EdgeInsets.all(16.0),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: Text(
                          'Est Time Left: ${_estimatedTime.toStringAsFixed(2)} minutes',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 10.0),
            GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => FullMapScreen(
                      currentPosition: _currentPosition,
                      polylines: _polylines,
                    ),
                  ),
                );
              },
              child: Container(
                height: 200,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: _currentPosition != null
                        ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
                        : LatLng(37.77483, -122.41942), // Updated initial position
                    zoom: 14, // Initial zoom level
                  ),
                  onMapCreated: (GoogleMapController controller) {
                    _controller.complete(controller);
                  },
                  polylines: _polylines,
                  myLocationEnabled: true,
                  myLocationButtonEnabled: false,
                ),
              ),
            ),
          ],
        )
            : Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class FullMapScreen extends StatelessWidget {
  final Position? currentPosition;
  final Set<Polyline> polylines;

  FullMapScreen({required this.currentPosition, required this.polylines});

  @override
  Widget build(BuildContext context) {
    Completer<GoogleMapController> _controller = Completer();

    return Scaffold(
      appBar: AppBar(
        title: Text('Full Map'),
      ),
      body: GoogleMap(
        initialCameraPosition: CameraPosition(
          target: currentPosition != null
              ? LatLng(currentPosition!.latitude, currentPosition!.longitude)
              : LatLng(37.77483, -122.41942), // Updated initial position
          zoom: 14, // Initial zoom level
        ),
        onMapCreated: (GoogleMapController controller) {
          _controller.complete(controller);
        },
        polylines: polylines,
        myLocationEnabled: true,
        myLocationButtonEnabled: true,
      ),
    );
  }
}
