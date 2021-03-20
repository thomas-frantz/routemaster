library routemaster;

export 'src/parser.dart';
export 'src/route_info.dart';
export 'src/pages/guard.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart';
import 'package:collection/collection.dart';
import 'src/pages/guard.dart';
import 'src/route_dart.dart';
import 'src/system_nav.dart';
import 'src/trie_router/trie_router.dart';
import 'src/route_info.dart';

part 'src/pages/stack.dart';
part 'src/pages/tab_pages.dart';
part 'src/pages/standard.dart';

typedef RoutemasterBuilder = Widget Function(
  BuildContext context,
  Routemaster routemaster,
);

typedef PageBuilder = Page Function(RouteInfo info);

typedef UnknownRouteCallback = Page? Function(
  Routemaster routemaster,
  String route,
  BuildContext context,
);

/// An abstract class that can provide a map of routes
abstract class RouteConfig {
  Map<String, PageBuilder> get routes;

  Page? onUnknownRoute(
      Routemaster routemaster, String route, BuildContext context) {
    routemaster.push('/');
  }
}

/// A standard simple routing table which takes a map of routes.
@immutable
class RouteMap extends RouteConfig {
  /// A map of paths and [PageBuilder] delegates that return [Page] objects to
  /// build.
  @override
  final Map<String, PageBuilder> routes;

  final UnknownRouteCallback? _onUnknownRoute;

  RouteMap({
    required this.routes,
    UnknownRouteCallback? onUnknownRoute,
  }) : _onUnknownRoute = onUnknownRoute;

  @override
  Page? onUnknownRoute(
      Routemaster routemaster, String route, BuildContext context) {
    if (_onUnknownRoute != null) {
      return _onUnknownRoute!(routemaster, route, context);
    }

    super.onUnknownRoute(routemaster, route, context);
  }
}

class Routemaster extends RouterDelegate<RouteData> with ChangeNotifier {
  /// Used to override how the [Navigator] builds.
  final RoutemasterBuilder? builder;
  final TransitionDelegate? transitionDelegate;

  // TODO: Could this have a better name?
  // Options: mapBuilder, builder, routeMapBuilder
  final RouteConfig Function(BuildContext context) routesBuilder;

  _RoutemasterState _state = _RoutemasterState();
  StackPageState? get _stack => _state.stack;
  late TrieRouter _router;
  RouteConfig? _routeMap;

  Routemaster({
    required this.routesBuilder,
    this.builder,
    this.transitionDelegate,
  });

  static Routemaster of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_RoutemasterWidget>()!
        .delegate;
  }

  /// Pop the top-most path from the router.
  void pop() {
    _stack!._pop();
    _markNeedsUpdate();
  }

  @override
  Future<bool> popRoute() {
    if (_stack == null) {
      return SynchronousFuture(false);
    }

    return _stack!._maybePop();
  }

  /// Passed to top-level [Navigator] widget, called when the navigator requests
  /// that it wants to pop a page.
  bool onPopPage(Route<dynamic> route, dynamic result) {
    return _stack!.onPopPage(route, result);
  }

  /// Pushes [path] into the navigation tree.
  void push(String path, {Map<String, String>? queryParameters}) {
    if (isAbsolute(path)) {
      _setLocation(path, queryParameters: queryParameters);
    } else {
      _setLocation(
        join(currentConfiguration!.routeString, path),
        queryParameters: queryParameters,
      );
    }
  }

  /// Replaces the current route with [path].
  void replace(String path, {Map<String, String>? queryParameters}) {
    if (kIsWeb) {
      final url = Uri(path: path, queryParameters: queryParameters);
      SystemNav.replaceLocation(url.toString());
    } else {
      push(path, queryParameters: queryParameters);
    }
  }

  /// Replace the entire route with the path from [path].
  void _setLocation(String path, {Map<String, String>? queryParameters}) {
    if (queryParameters != null) {
      path = Uri(
        path: path,
        queryParameters: queryParameters,
      ).toString();
    }

    if (_isBuilding) {
      // About to build pages, process request now
      _processNavigation(path);
    } else {
      // Schedule request for next build. This makes sure the routing table is
      // updated before processing the new path.
      _pendingNavigation = path;
      notifyListeners();
    }
  }

  String? _pendingNavigation;
  bool _isBuilding = false;

  void _processPendingNavigation() {
    if (_pendingNavigation != null) {
      _processNavigation(_pendingNavigation!);
      _pendingNavigation = null;
    }
  }

  void _processNavigation(String path) {
    final states = _createAllStates(path);
    if (states == null) {
      return;
    }

    _stack!._setPageStates(states);
  }

  @override
  Widget build(BuildContext context) {
    return _DependencyTracker(
      delegate: this,
      builder: (context) {
        _isBuilding = true;
        _processPendingNavigation();
        final pages = createPages(context);
        _isBuilding = false;

        return _RoutemasterWidget(
          delegate: this,
          child: builder != null
              ? builder!(context, this)
              : Navigator(
                  pages: pages,
                  onPopPage: onPopPage,
                  key: _stack!.navigatorKey,
                  transitionDelegate: transitionDelegate ??
                      const DefaultTransitionDelegate<dynamic>(),
                ),
        );
      },
    );
  }

  // Returns a [RouteData] that matches the current route state.
  // This is used to update a browser's current URL.
  @override
  RouteData? get currentConfiguration {
    if (_stack == null) {
      return null;
    }

    final path = _stack!._getCurrentPageStates().last._routeInfo.path;
    return RouteData(path);
  }

  // Called when a new URL is set. The RouteInformationParser will parse the
  // URL, and return a new [RouteData], that gets passed this this method.
  //
  // This method then modifies the state based on that information.
  @override
  Future<void> setNewRoutePath(RouteData routeData) {
    if (currentConfiguration != routeData) {
      final states = _createAllStates(routeData.routeString);
      if (states != null) {
        _stack!._setPageStates(states);
      }
    }

    return SynchronousFuture(null);
  }

  /// This delegate maintains state by using a `StatefulWidget` inserted in the
  /// widget tree. This means it can maintain state if the delegate is rebuilt
  /// in the same tree location.
  ///
  /// TODO: Should this reuse more data for performance?
  void _didUpdateWidget(Routemaster oldDelegate) {
    final oldConfiguration = oldDelegate.currentConfiguration;

    if (oldConfiguration != null) {
      _oldConfiguration = oldDelegate.currentConfiguration;
    }
  }

  void _rebuild(BuildContext context) {
    if (currentConfiguration == null) {
      return;
    }

    _buildRouter(context);

    _isBuilding = true;
    final path = currentConfiguration!.routeString;
    final pageStates = _createAllStates(currentConfiguration!.routeString);
    if (pageStates == null) {
      print(
        "Router rebuilt but no match for '$path'. Assuming navigation is about to happen.",
      );
      return;
    }
    _state.stack = StackPageState(delegate: this, routes: pageStates.toList());
    _isBuilding = false;
  }

  void _buildRouter(BuildContext context) {
    final routeMap = routesBuilder(context);

    _router = TrieRouter()..addAll(routeMap.routes);
    WidgetsBinding.instance?.addPostFrameCallback((_) {
      notifyListeners();
    });

    _routeMap = routeMap;
  }

  RouteData? _oldConfiguration;

  void _initRoutes(BuildContext context) {
    if (_routeMap == null) {
      _buildRouter(context);
    }

    if (_stack == null) {
      final pageStates = _createAllStates(_oldConfiguration?.routeString ??
          currentConfiguration?.routeString ??
          '/');
      if (pageStates == null) {
        throw 'Failed to create initial state';
      }

      _state.stack =
          StackPageState(delegate: this, routes: pageStates.toList());
    }
  }

  /// Generates all pages and sub-pages.
  List<Page> createPages(BuildContext context) {
    _initRoutes(context);

    assert(_stack != null,
        'Stack must have been created when createPages() is called');
    final pages = _stack!.createPages();
    assert(pages.isNotEmpty, 'Returned pages list must not be empty');
    return pages;
  }

  void _markNeedsUpdate() {
    if (!_isBuilding) {
      notifyListeners();
    }
  }

  List<_PageState>? _createAllStates(String requestedPath) {
    final routerResult = _router.getAll(requestedPath);

    if (routerResult == null) {
      print(
        "Router couldn't find a match for path '$requestedPath''",
      );

      final result = _routeMap!.onUnknownRoute(
          this, requestedPath, _state.globalKey.currentContext!);
      if (result == null) {
        // No 404 page returned
        return null;
      }

      // Show 404 page
      final routeInfo = RouteInfo(requestedPath, (_) => result);
      return [_StatelessPage(routeInfo, result)];
    }

    final currentRoutes = _stack?._getCurrentPageStates().toList();

    var result = <_PageState>[];

    var i = 0;
    for (final routerData in routerResult.reversed) {
      final routeInfo = RouteInfo.fromRouterResult(
        routerData,
        // Only the last route gets query parameters
        i == 0 ? requestedPath : routerData.pathSegment,
      );

      final state = _getOrCreatePageState(routeInfo, currentRoutes, routerData);

      if (state == null) {
        return null;
      }

      if (result.isNotEmpty && state._maybeSetPageStates(result)) {
        result = [state];
      } else {
        result.insert(0, state);
      }

      i++;
    }

    assert(result.isNotEmpty, "_createAllStates can't return empty list");
    return result;
  }

  /// If there's a current route matching the path in the tree, return it.
  /// Otherwise create a new one. This could possibly be made more efficient
  /// By using a map rather than iterating over all currentRoutes.
  _PageState? _getOrCreatePageState(
    RouteInfo routeInfo,
    List<_PageState>? currentRoutes,
    RouterResult routerResult,
  ) {
    if (currentRoutes != null) {
      print(
          " - Trying to find match for state matching '${routeInfo.path}'...");
      final currentState = currentRoutes.firstWhereOrNull(
        ((element) => element._routeInfo == routeInfo),
      );

      if (currentState != null) {
        print(' - Found match for state');
        return currentState;
      }

      print(' - No match for state, will need to create it');
    }

    return _createState(routerResult, routeInfo);
  }

  /// Try to get the route for [requestedPath]. If no match, returns default path.
  /// Returns null if validation fails.
  _PageState? _getRoute(String requestedPath) {
    final routerResult = _router.get(requestedPath);
    if (routerResult == null) {
      print(
        "Router couldn't find a match for path '$requestedPath'",
      );

      _routeMap!.onUnknownRoute(
          this, requestedPath, _state.globalKey.currentContext!);
      return null;
    }

    final routeInfo = RouteInfo.fromRouterResult(routerResult, requestedPath);
    return _createState(routerResult, routeInfo);
  }

  _PageState? _createState(RouterResult routerResult, RouteInfo routeInfo) {
    var page = routerResult.builder(routeInfo);

    if (page is GuardedPage) {
      final context = _state.globalKey.currentContext!;
      if (page.validate != null && !page.validate!(routeInfo, context)) {
        print("Validation failed for '${routeInfo.path}'");
        page.onValidationFailed!(this, routeInfo, context);
        return null;
      }

      page = page.child;
    }

    if (page is StatefulPage) {
      return page.createState(this, routeInfo);
    }

    assert(page is! ProxyPage, 'ProxyPage has not been unwrapped');

    // Page is just a standard Flutter page, create a wrapper for it
    return _StatelessPage(routeInfo, page);
  }
}

/// Used internally so descendent widgets can use `Routemaster.of(context)`.
class _RoutemasterWidget extends InheritedWidget {
  final Routemaster delegate;

  const _RoutemasterWidget({
    required Widget child,
    required this.delegate,
  }) : super(child: child);

  @override
  bool updateShouldNotify(covariant _RoutemasterWidget oldWidget) {
    return delegate != oldWidget.delegate;
  }
}

class _RoutemasterState {
  StackPageState? stack;
  final globalKey = GlobalKey();
}

/// Widget to trigger router rebuild when dependencies change
class _DependencyTracker extends StatefulWidget {
  final Routemaster delegate;
  final Widget Function(BuildContext context) builder;

  _DependencyTracker({
    required this.delegate,
    required this.builder,
  });

  @override
  _DependencyTrackerState createState() => _DependencyTrackerState();
}

class _DependencyTrackerState extends State<_DependencyTracker> {
  late _RoutemasterState _delegateState;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _delegateState.globalKey,
      child: widget.builder(context),
    );
  }

  @override
  void initState() {
    super.initState();
    _delegateState = widget.delegate._state;
    widget.delegate._state = _delegateState;
  }

  @override
  void didUpdateWidget(_DependencyTracker oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.delegate._state = _delegateState;
    widget.delegate._didUpdateWidget(oldWidget.delegate);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.delegate._rebuild(this.context);
  }
}
