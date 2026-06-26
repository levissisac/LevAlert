import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:vibration/vibration.dart';

const String tomTomApiKey = "K0PHaEwQMMTLqrFRMR1YEK35GwnosO8U";

void main() {
  runApp(const LocationAlarmApp());
}

class LocationAlarmApp extends StatelessWidget {
  const LocationAlarmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "LevAlert",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
        ),
        scaffoldBackgroundColor: const Color(0xFFF6F7FB),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF6F7FB),
          foregroundColor: Color(0xFF111827),
          elevation: 0,
        ),
      ),
      home: const LocationScreen(),
    );
  }
}

class LocationScreen extends StatefulWidget {
  const LocationScreen({super.key});

  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class PlaceSuggestion {
  final String name;
  final double lat;
  final double lon;

  PlaceSuggestion({
    required this.name,
    required this.lat,
    required this.lon,
  });

  // Nominatim (OpenStreetMap) — best coverage of Indian local places,
  // KSRTC stands, bus stops, local landmarks etc.
  factory PlaceSuggestion.fromNominatim(Map<String, dynamic> json) {
    return PlaceSuggestion(
      name: json['display_name'] as String,
      lat: double.parse(json['lat'] as String),
      lon: double.parse(json['lon'] as String),
    );
  }
}

class _LocationScreenState extends State<LocationScreen> {
  static const MethodChannel alarmChannel =
      MethodChannel('location_alarm/default_alarm');

  final TextEditingController destinationController = TextEditingController();
  final FocusNode searchFocus = FocusNode();
  final ScrollController scrollController = ScrollController();
  final FlutterLocalNotificationsPlugin notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  final MapController mapController = MapController();

  double? destinationLat;
  double? destinationLon;

  LatLng? currentPoint;
  LatLng mapCenter = const LatLng(9.5916, 76.5222); // Pala, Kerala default

  List<LatLng> routePoints = [];
  List<PlaceSuggestion> suggestions = [];

  double? routeDistanceKm;

  Timer? trackingTimer;
  Timer? searchDebounce;

  bool isTracking = false;
  bool isCalculating = false;
  bool isSearching = false;
  bool alarmTriggered = false;
  bool isPreviewPlaying = false;
  bool showCoordinates = false;

  double alertDistanceKm = 1.0;
  String result = "Search for a destination";
  String? searchError;

  double? currentLat;
  double? currentLon;
  double? lastDisplayedDistanceKm;

  @override
  void initState() {
    super.initState();
    initializeNotifications();
    destinationController.addListener(() {
      setState(() {}); // rebuild so the clear (X) button shows/hides live
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      updateCurrentLocationOnMap();
    });
  }

  Future<void> initializeNotifications() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidSettings);
    await notificationsPlugin.initialize(settings);
    await notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  Future<void> showArrivalNotification() async {
    const androidDetails = AndroidNotificationDetails(
      'destination_alarm_channel',
      'Destination Alarm',
      channelDescription: 'Alerts when you are near your destination',
      importance: Importance.max,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);
    await notificationsPlugin.show(
      0,
      'Destination reached!',
      'You are within the selected road distance.',
      details,
    );
  }

  Future<bool> checkLocationPermission() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission != LocationPermission.denied &&
        permission != LocationPermission.deniedForever;
  }

  Future<void> updateCurrentLocationOnMap() async {
    final hasPermission = await checkLocationPermission();
    if (!hasPermission) {
      setState(() => result = "Location permission denied");
      return;
    }
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      final point = LatLng(position.latitude, position.longitude);
      setState(() {
        currentPoint = point;
        mapCenter = point;
      });
      mapController.move(point, 15);
      await fetchRoute();
    } catch (e) {
      debugPrint('updateCurrentLocationOnMap error: $e');
      setState(() => result = "Error getting current location");
    }
  }

  /// Builds a bounding box (viewbox) roughly `marginDegrees` around the
  /// given center. ~0.5 degrees latitude is roughly 55km, which gives a
  /// generous "nearby" search radius around the user.
  String _viewboxAround(LatLng center, {double marginDegrees = 0.6}) {
    final left = center.longitude - marginDegrees;
    final top = center.latitude + marginDegrees;
    final right = center.longitude + marginDegrees;
    final bottom = center.latitude - marginDegrees;
    return "$left,$top,$right,$bottom";
  }

  /// Search via Nominatim, biased toward the user's current location (or
  /// the default Kerala map center) using a viewbox. `bounded=0` keeps the
  /// box as a *soft* preference rather than a hard cutoff — nearby matches
  /// rank first, but a typed place far away can still appear if nothing
  /// closer matches, similar to how Google Maps search behaves.
  void clearSearch() {
    // Stop any active tracking/alarm first.
    trackingTimer?.cancel();
    if (alarmTriggered || isPreviewPlaying) {
      alarmChannel.invokeMethod('stopDefaultAlarm');
      Vibration.cancel();
    }

    destinationController.clear();

    setState(() {
      // Search state
      suggestions = [];
      searchError = null;

      // Destination & route state
      destinationLat = null;
      destinationLon = null;
      routePoints = [];
      routeDistanceKm = null;
      lastDisplayedDistanceKm = null;

      // Tracking / alarm state
      isTracking = false;
      isCalculating = false;
      alarmTriggered = false;
      isPreviewPlaying = false;
      showCoordinates = false;

      result = "Search for a destination";
    });

    // Re-center the map back on the current location, like a fresh start.
    if (currentPoint != null) {
      mapController.move(currentPoint!, 15);
    }
  }

  Future<void> searchPlaces(String query) async {
    final trimmedQuery = query.trim();
    if (trimmedQuery.length < 3) {
      setState(() {
        suggestions = [];
        searchError = null;
      });
      return;
    }

    setState(() {
      isSearching = true;
      searchError = null;
    });

    try {
      final biasCenter = currentPoint ?? mapCenter;
      final viewbox = _viewboxAround(biasCenter);

      final url = Uri.https(
        'nominatim.openstreetmap.org',
        '/search',
        {
          'q': trimmedQuery,
          'format': 'json',
          'limit': '8',
          'addressdetails': '1',
          'viewbox': viewbox,
          'bounded': '0', // soft bias, not a hard cutoff
        },
      );

      final response = await http
          .get(url, headers: {'User-Agent': 'levalert_app_kerala'})
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as List;

        if (data.isEmpty) {
          setState(() {
            suggestions = [];
            isSearching = false;
            searchError = "No places found for \"$trimmedQuery\"";
          });
          return;
        }

        final results = data
            .map((item) =>
                PlaceSuggestion.fromNominatim(item as Map<String, dynamic>))
            .toList();

        // Sort by distance to the bias center so the nearest result is
        // always first, even though Nominatim's own ordering can be loose.
        results.sort((a, b) {
          final distA = Geolocator.distanceBetween(
            biasCenter.latitude,
            biasCenter.longitude,
            a.lat,
            a.lon,
          );
          final distB = Geolocator.distanceBetween(
            biasCenter.latitude,
            biasCenter.longitude,
            b.lat,
            b.lon,
          );
          return distA.compareTo(distB);
        });

        setState(() {
          suggestions = results;
          isSearching = false;
          searchError = null;
        });
      } else {
        setState(() {
          suggestions = [];
          isSearching = false;
          searchError = "Search failed (code ${response.statusCode})";
        });
      }
    } catch (e) {
      debugPrint('searchPlaces error: $e');
      if (!mounted) return;
      setState(() {
        suggestions = [];
        isSearching = false;
        searchError = "Search failed. Check your internet connection.";
      });
    }
  }

  Future<void> selectPlace(PlaceSuggestion place) async {
    final selectedPoint = LatLng(place.lat, place.lon);
    setState(() {
      destinationController.text = place.name;
      destinationLat = place.lat;
      destinationLon = place.lon;
      mapCenter = selectedPoint;
      suggestions = [];
      searchError = null;
      result = "Destination Selected";
    });
    mapController.move(selectedPoint, 15);
    await calculateDistance();
  }

  Future<double?> fetchRoute() async {
    if (currentPoint == null ||
        destinationLat == null ||
        destinationLon == null) return null;

    try {
      final url = Uri.parse(
        "https://api.tomtom.com/routing/1/calculateRoute/"
        "${currentPoint!.latitude},${currentPoint!.longitude}:"
        "$destinationLat,$destinationLon/json"
        "?key=$tomTomApiKey"
        "&routeType=fastest"
        "&traffic=true",
      );

      final response =
          await http.get(url).timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final routes = data["routes"] as List? ?? [];

        if (routes.isEmpty) {
          if (!mounted) return null;
          setState(() {
            routePoints = [];
            routeDistanceKm = null;
          });
          return null;
        }

        final route = routes[0];
        final summary = route["summary"];
        final distanceMeters = summary["lengthInMeters"] as num;
        final distanceKm = distanceMeters / 1000;

        final legs = route["legs"] as List;
        final List<LatLng> points = [];
        for (final leg in legs) {
          final legPoints = leg["points"] as List;
          for (final p in legPoints) {
            points.add(LatLng(
              (p["latitude"] as num).toDouble(),
              (p["longitude"] as num).toDouble(),
            ));
          }
        }

        if (!mounted) return distanceKm.toDouble();
        setState(() {
          routeDistanceKm = distanceKm.toDouble();
          routePoints = points;
        });
        return distanceKm.toDouble();
      }
    } catch (e) {
      debugPrint('fetchRoute error: $e');
      if (!mounted) return null;
      setState(() {
        routePoints = [];
        routeDistanceKm = null;
      });
    }
    return null;
  }

  Future<void> calculateDistance() async {
    if (destinationLat == null || destinationLon == null) {
      setState(() => result = "Search for a destination first");
      return;
    }
    setState(() => isCalculating = true);
    try {
      final hasPermission = await checkLocationPermission();
      if (!hasPermission) {
        setState(() {
          result = "Location permission denied";
          isCalculating = false;
        });
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      final point = LatLng(position.latitude, position.longitude);
      setState(() {
        currentPoint = point;
        currentLat = position.latitude;
        currentLon = position.longitude;
      });
      final roadDistanceKm = await fetchRoute();
      if (!mounted) return;

      // Zoom/pan the map to fit the whole route in view, like the
      // destination-search flow in Google Maps.
      if (roadDistanceKm != null && routePoints.length > 1) {
        try {
          final bounds = LatLngBounds.fromPoints(routePoints);
          mapController.fitCamera(
            CameraFit.bounds(
              bounds: bounds,
              padding: const EdgeInsets.all(48),
            ),
          );
        } catch (e) {
          debugPrint('fitCamera error: $e');
        }
      }

      setState(() {
        lastDisplayedDistanceKm = roadDistanceKm;
        isCalculating = false;
        result = roadDistanceKm == null
            ? "Road route unavailable. Try a destination near a road."
            : "Ready to track";
      });
    } catch (e) {
      debugPrint('calculateDistance error: $e');
      if (!mounted) return;
      setState(() {
        result = "Error calculating distance";
        isCalculating = false;
      });
    }
  }

  Future<void> togglePreview() async {
    if (isPreviewPlaying) {
      await alarmChannel.invokeMethod('stopDefaultAlarm');
      Vibration.cancel();
      setState(() {
        isPreviewPlaying = false;
        result = "Preview stopped";
      });
    } else {
      setState(() {
        isPreviewPlaying = true;
        result = "Preview alarm running...";
      });
      await alarmChannel.invokeMethod('playDefaultAlarm');
      if (await Vibration.hasVibrator()) {
        Vibration.vibrate(pattern: [500, 1000, 500, 1000], repeat: 0);
      }
    }
  }

  Future<void> triggerAlarm(double distanceKm) async {
    if (alarmTriggered) return;
    if (isPreviewPlaying) {
      setState(() => isPreviewPlaying = false);
    }
    setState(() {
      alarmTriggered = true;
      result =
          "You have arrived! ${distanceKm.toStringAsFixed(2)} km remaining";
    });
    await showArrivalNotification();
    await alarmChannel.invokeMethod('playDefaultAlarm');
    if (await Vibration.hasVibrator()) {
      Vibration.vibrate(pattern: [500, 1000, 500, 1000], repeat: 0);
    }
  }

  Future<void> stopAlarm() async {
    await alarmChannel.invokeMethod('stopDefaultAlarm');
    Vibration.cancel();
    setState(() {
      alarmTriggered = false;
      isPreviewPlaying = false;
      result = "Alarm stopped";
    });
  }

  Future<void> startTracking() async {
    if (destinationLat == null || destinationLon == null) {
      setState(() => result = "Search for a destination first");
      return;
    }
    final hasPermission = await checkLocationPermission();
    if (!hasPermission) {
      setState(() => result = "Location permission denied");
      return;
    }
    trackingTimer?.cancel();
    setState(() {
      isTracking = true;
      result = "Tracking started...";
    });

    // Snap map to current location immediately, zoomed in like Google
    // Maps navigation mode.
    try {
      final startPosition = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      final startPoint =
          LatLng(startPosition.latitude, startPosition.longitude);
      if (mounted) {
        setState(() {
          currentPoint = startPoint;
          currentLat = startPosition.latitude;
          currentLon = startPosition.longitude;
        });
        mapController.move(startPoint, 16);
      }
    } catch (e) {
      debugPrint('startTracking initial position error: $e');
    }

    trackingTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.high),
        );
        final currentLocationPoint =
            LatLng(position.latitude, position.longitude);
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() {
          currentPoint = currentLocationPoint;
          currentLat = position.latitude;
          currentLon = position.longitude;
        });
        // Follow the user's live position on the map, like Google Maps
        // navigation mode.
        mapController.move(currentLocationPoint, 16);

        final remainingKm = await fetchRoute();
        if (!mounted) {
          timer.cancel();
          return;
        }
        if (remainingKm == null) {
          setState(() {
            lastDisplayedDistanceKm = null;
            result = "Tracking... road route unavailable, retrying";
          });
          return;
        }
        setState(() => lastDisplayedDistanceKm = remainingKm);
        if (remainingKm <= alertDistanceKm) {
          timer.cancel();
          setState(() => isTracking = false);
          await triggerAlarm(remainingKm);
          return;
        }
        setState(() => result = "Tracking active");
      } catch (e) {
        debugPrint('tracking tick error: $e');
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => result = "Tracking error");
      }
    });
  }

  void stopTracking() {
    trackingTimer?.cancel();
    setState(() {
      isTracking = false;
      result = "Tracking stopped";
    });
  }

  Future<void> toggleTracking() async {
    if (isTracking) {
      stopTracking();
      return;
    }

    if (destinationLat == null || destinationLon == null) {
      // No destination yet — guide the user to the search box.
      scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
      setState(() => result = "Search for a destination first ↑");
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      searchFocus.requestFocus();
      return;
    }

    await startTracking();
  }

  @override
  void dispose() {
    trackingTimer?.cancel();
    searchDebounce?.cancel();
    searchFocus.dispose();
    scrollController.dispose();
    alarmChannel.invokeMethod('stopDefaultAlarm');
    Vibration.cancel();
    destinationController.dispose();
    super.dispose();
  }

  Widget _panel({required Widget child, Color color = Colors.white}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x10000000),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final destinationPoint = destinationLat != null && destinationLon != null
        ? LatLng(destinationLat!, destinationLon!)
        : null;

    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "LevAlert",
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            Text(
              "Track destination alerts",
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
        actions: [
          IconButton.filledTonal(
            onPressed: alarmTriggered ? null : () => togglePreview(),
            icon: Icon(isPreviewPlaying ? Icons.volume_off : Icons.volume_up),
            tooltip: isPreviewPlaying ? "Stop Preview" : "Preview Alarm",
            style: isPreviewPlaying
                ? IconButton.styleFrom(
                    backgroundColor: const Color(0xFFDC2626),
                    foregroundColor: Colors.white)
                : null,
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            onPressed: updateCurrentLocationOnMap,
            icon: const Icon(Icons.my_location),
            tooltip: "My Location",
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Search panel ────────────────────────────────────────
            _panel(
              child: Column(
                children: [
                  TextField(
                    controller: destinationController,
                    focusNode: searchFocus,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: isSearching
                          ? const Padding(
                              padding: EdgeInsets.all(14),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              ),
                            )
                          : destinationController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.close, size: 18),
                                  tooltip: "Clear",
                                  onPressed: clearSearch,
                                )
                              : null,
                      labelText: "Where do you want to go?",
                      hintText: "Type pala, ksrtc, vellarikundu...",
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      searchDebounce?.cancel();
                      searchDebounce = Timer(
                        const Duration(milliseconds: 500),
                        () => searchPlaces(value),
                      );
                    },
                  ),
                  if (searchError != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.error_outline,
                            size: 16, color: Color(0xFFDC2626)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            searchError!,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFFDC2626)),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (suggestions.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Material(
                        color: const Color(0xFFF9FAFB),
                        child: ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: suggestions.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final place = suggestions[index];
                            return ListTile(
                              leading: const Icon(Icons.place_outlined),
                              title: Text(
                                place.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => selectPlace(place),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 14),

            // ── Map ─────────────────────────────────────────────────
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: SizedBox(
                height: 260,
                child: FlutterMap(
                  mapController: mapController,
                  options: MapOptions(
                    initialCenter: mapCenter,
                    initialZoom: 13,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                      userAgentPackageName:
                          "com.example.location_alarm_prototype",
                    ),
                    if (routePoints.isNotEmpty)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: routePoints,
                            color: const Color(0xFF2563EB),
                            strokeWidth: 5,
                          ),
                        ],
                      ),
                    if (destinationPoint != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: destinationPoint,
                            width: 52,
                            height: 52,
                            child: const Icon(
                              Icons.location_pin,
                              color: Color(0xFFDC2626),
                              size: 46,
                            ),
                          ),
                        ],
                      ),
                    if (currentPoint != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: currentPoint!,
                            width: 48,
                            height: 48,
                            child: Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFF2563EB),
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: Colors.white, width: 4),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black26,
                                    blurRadius: 8,
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.navigation,
                                color: Colors.white,
                                size: 24,
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 14),

            // ── ACTION ZONE — calculating / distance+stopbtn / big start ──
            if (isCalculating) ...[
              _panel(
                child: Row(
                  children: [
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Getting your location...",
                            style: TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 14),
                          ),
                          SizedBox(height: 2),
                          Text(
                            "Fetching road distance",
                            style:
                                TextStyle(fontSize: 12, color: Colors.black45),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (lastDisplayedDistanceKm != null) ...[
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _panel(
                        color: isTracking
                            ? const Color(0xFFEFF6FF)
                            : alarmTriggered
                                ? const Color(0xFFFEF2F2)
                                : Colors.white,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.route,
                                  size: 15,
                                  color: alarmTriggered
                                      ? const Color(0xFFDC2626)
                                      : const Color(0xFF2563EB),
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  alarmTriggered
                                      ? "ARRIVED!"
                                      : isTracking
                                          ? "TRACKING"
                                          : "Road Distance",
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.5,
                                    color: alarmTriggered
                                        ? const Color(0xFFDC2626)
                                        : const Color(0xFF2563EB),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              "${lastDisplayedDistanceKm!.toStringAsFixed(2)} km",
                              style: const TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF111827),
                                height: 1,
                              ),
                            ),
                            const SizedBox(height: 4),
                            GestureDetector(
                              onTap: () => setState(
                                  () => showCoordinates = !showCoordinates),
                              child: Row(
                                children: [
                                  Icon(
                                    showCoordinates
                                        ? Icons.expand_less
                                        : Icons.expand_more,
                                    size: 14,
                                    color: Colors.black45,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    showCoordinates
                                        ? "Hide coordinates"
                                        : "Show coordinates",
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.black45,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (showCoordinates && currentLat != null) ...[
                              const SizedBox(height: 10),
                              const Divider(height: 1),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          "LAT",
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.black45,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                        Text(
                                          currentLat!.toStringAsFixed(6),
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          "LON",
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.black45,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                        Text(
                                          currentLon!.toStringAsFixed(6),
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: () => toggleTracking(),
                      child: Container(
                        width: 90,
                        constraints: const BoxConstraints(minHeight: 110),
                        decoration: BoxDecoration(
                          color: isTracking
                              ? const Color(0xFFDC2626)
                              : const Color(0xFF2563EB),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x22000000),
                              blurRadius: 12,
                              offset: Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              isTracking
                                  ? Icons.stop_rounded
                                  : Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 38,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              isTracking ? "STOP" : "START",
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              GestureDetector(
                onTap: () => toggleTracking(),
                child: Container(
                  height: 60,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2563EB),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x22000000),
                        blurRadius: 12,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.play_arrow_rounded,
                          color: Colors.white, size: 30),
                      SizedBox(width: 8),
                      Text(
                        "START TRACKING",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],

            const SizedBox(height: 14),

            // ── Alert distance slider ────────────────────────────────
            _panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Text(
                        "Alert Distance",
                        style: TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 15),
                      ),
                      const Spacer(),
                      Text(
                        "${alertDistanceKm.toStringAsFixed(1)} km",
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF2563EB),
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: alertDistanceKm,
                    min: 0.1,
                    max: 5.0,
                    divisions: 49,
                    label: alertDistanceKm.toStringAsFixed(1),
                    onChanged: (value) =>
                        setState(() => alertDistanceKm = value),
                  ),
                ],
              ),
            ),

            // ── Stop Alarm button (only while alarm is firing) ───────
            if (alarmTriggered) ...[
              const SizedBox(height: 14),
              GestureDetector(
                onTap: stopAlarm,
                child: Container(
                  height: 56,
                  decoration: BoxDecoration(
                    color: const Color(0xFFDC2626),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x22000000),
                        blurRadius: 12,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.notifications_off, color: Colors.white),
                      SizedBox(width: 8),
                      Text(
                        "STOP ALARM",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],

            const SizedBox(height: 14),

            // ── Status panel ────────────────────────────────────────
            _panel(
              color: isTracking
                  ? const Color(0xFFEFF6FF)
                  : alarmTriggered
                      ? const Color(0xFFFEF2F2)
                      : Colors.white,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    alarmTriggered
                        ? Icons.notification_important
                        : isTracking
                            ? Icons.route
                            : Icons.info_outline,
                    color: alarmTriggered
                        ? const Color(0xFFDC2626)
                        : const Color(0xFF2563EB),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      result,
                      style: const TextStyle(fontSize: 14, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
