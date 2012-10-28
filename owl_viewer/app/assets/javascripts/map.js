var MIN_ZOOM_LEVEL = 1;
var lon = 5;
var lat = 40;
var zoom = 5;
var map, layerBasic, layerVector, browseBoxControl;

function setupView(){
  map.zoomToExtent(layerVector.getDataExtent(), false);
}

function showFeaturePopup(e) {
  $('li[class="changeset_item_selected"]').attr('class', 'changeset_item');
  $('li[id="changeset_' + e.feature.data.changeset_id +'"]').attr('class', 'changeset_item_selected');
  //    $('#visstatus').scrollTo('li[id="changeset_' + e.feature.data.changeset_id +'"]');
}

function hideFeaturePopup(e) {
  $('li[class="changeset_item_selected"]').attr('class', 'changeset_item');
}

function zoomEvent() {
  var vis = map.getZoom() > MIN_ZOOM_LEVEL;
  layerVector.setVisibility(vis);
  //document.getElementById("visstatus").style.visibility = vis ? "hidden" : "visible";
  if (!vis) {
    $("#changeset_list").html('<p align="center" style="color:red; text-style:sans-serif;">Data not visible at this zoom level, please zoom in to see stuff.</p>');
  }
}

// liberally stolen from osm.org
function updateLocation() {
  var lonlat = map.getCenter().transform(map.getProjectionObject(), map.displayProjection);
  var zoom = map.getZoom();
  var expiry = new Date();

  expiry.setYear(expiry.getFullYear() + 10);
  var cookie_string = "_owl_location=" + lonlat.lon + "|" + lonlat.lat + "|" + zoom + "; expires=" + expiry.toGMTString();
  document.cookie = cookie_string;
}

// liberally stolen from OpenCycleMap. thanks, Andy!
function readCookie(name) {
  var nameEQ = name + "=";
  var ca = document.cookie.split(';');
  for(var i=0;i < ca.length;i++) {
          var c = ca[i];
          while (c.charAt(0)==' ') c = c.substring(1,c.length);
          if (c.indexOf(nameEQ) == 0) return c.substring(nameEQ.length,c.length);
  }
  return null;
}

// liberally stolen from OpenCycleMap. thanks, Andy!
function setCentreFromCookie() {
  var centre = new OpenLayers.LonLat(-1.85, 53.8);
  var zoom = 6;
  var cookietext = readCookie('_owl_location');
  if (cookietext) {
    var cb = cookietext.split('|');
    centre = new OpenLayers.LonLat(cb[0], cb[1]);
    zoom = cb[2];
    }
  map.setCenter(centre.transform(map.displayProjection, map.getProjectionObject()), zoom);
}

function getChangesetIdFromElement(el) {
  var el_id = $(el).attr('id');

  if(!el_id) {
    el_id = $(el.parentElement).attr('id');
  }

  return parseInt(el_id.replace('changeset_', ''));
}

function init(){
  map = new OpenLayers.Map ("map", {
      controls:[
          new OpenLayers.Control.Navigation(),
          new OpenLayers.Control.PanZoomBar(),
          new OpenLayers.Control.Attribution(),
          new OpenLayers.Control.Permalink(),
          new OpenLayers.Control.MousePosition(),
          new OpenLayers.Control.LayerSwitcher()],
      maxExtent: new OpenLayers.Bounds(-20037508.34,-20037508.34,20037508.34,20037508.34),
      maxResolution: 156543.0399,
      numZoomLevels: 19,
      units: 'm',
      projection: new OpenLayers.Projection("EPSG:900913"),
      displayProjection: new OpenLayers.Projection("EPSG:4326")
  } );

  layerBasic = new OpenLayers.Layer.OSM();
  map.addLayer(layerBasic);

  var strategy = new OpenLayers.Strategy.BBOX({resFactor: 1, ratio: 1});

  layerVector = new OpenLayers.Layer.Vector("Polygon (Forever)", {
       strategies: [strategy],
       protocol: new OpenLayers.Protocol.HTTP({
           url: "changesets.geojson",
           format: new OpenLayers.Format.GeoJSON()
       }),
       projection: new OpenLayers.Projection("EPSG:4326"),
       displayProjection: new OpenLayers.Projection("EPSG:900913"),
       styleMap: new OpenLayers.StyleMap({
         "default": {'strokeWidth': 8, 'strokeColor': "yellow", 'strokeOpacity': 0.66, pointRadius: 3, fillColor: "yellow"},
         "highlight": {'strokeWidth': 8, 'strokeColor': "blue", pointRadius: 3, fillColor: "yellow"}
       }),
       visibility: false
  });
  map.addLayer(layerVector);

  var highlightControl = new OpenLayers.Control.SelectFeature(layerVector,
      { "hover": true,
        "highlightOnly": true,
        "renderIntent": "highlight",
        "eventListeners": {
                    featurehighlighted: showFeaturePopup,
                    featureunhighlighted: hideFeaturePopup
                }});

  map.addControl(highlightControl);
  highlightControl.activate();

  layerVector.events.on({
    'loadend': function(obj) {
      if (map.getZoom() > MIN_ZOOM_LEVEL) {
        $("#changeset_list").html($("#changeset_list_template").render(obj.object));

        var bbox = map.getExtent().transform('EPSG:900913', 'EPSG:4326').toBBOX(10, false);
        $("#rss_link").attr('href', '/map.rss?bbox=' + bbox);

        $(".changeset_item").on('hover', function(e) {
          if (e.type == 'mouseenter') {
            // Highlight row in the list.
            $(e.target).attr('class', 'changeset_item_selected');
          } else if (e.type == 'mouseleave') {
            $('li[class="changeset_item_selected"]').attr('class', 'changeset_item');
          }

          // Highlight geometry.
          var changeset_id = getChangesetIdFromElement(e.target);
          var features = layerVector.getFeaturesByAttribute('changeset_id', changeset_id);
          if (features.length > 0) {
            if (e.type == 'mouseenter') {
              highlightControl.select(features[0]);
            } else if (e.type == 'mouseleave') {
              highlightControl.unselect(features[0]);
            }
          }
        });

        $(".changeset_item").on('click', function(e) {
          // Zoom to geometry.
          var changeset_id = getChangesetIdFromElement(e.target);
          var features = layerVector.getFeaturesByAttribute('changeset_id', changeset_id);
          if (features.length > 0) {
            var dataExtent = features[0].geometry.getBounds();
            map.zoomToExtent(dataExtent, closest=true);
          }
        });
      }
    }
  }

  );

  map.events.register("zoomend", this, zoomEvent);
  map.events.register("moveend", map, updateLocation);

  if (!map.getCenter()) setCentreFromCookie();
}
