require 'logging'
require 'utils'

module Tiler

# Implements tiling logic.
class Tiler
  include ::Tiler::Logger

  attr_accessor :conn

  def initialize(conn)
    @conn = conn
    @conn.exec('DROP TABLE IF EXISTS _way_geom')
    @conn.exec('DROP TABLE IF EXISTS _tile_bboxes')
    @conn.exec('DROP TABLE IF EXISTS _tile_changes_tmp')
    @conn.exec('CREATE TEMPORARY TABLE _way_geom (geom geometry, tstamp timestamp without time zone);')
    @conn.exec('CREATE TEMPORARY TABLE _tile_bboxes (x int, y int, zoom int, tile_bbox geometry);')
    @conn.exec('CREATE TEMPORARY TABLE _tile_changes_tmp (el_type element_type NOT NULL, tstamp timestamp without time zone,
      x int, y int, zoom int, tile_geom geometry);')
    @conn.exec('CREATE INDEX _idx_way_geom ON _way_geom USING gist (geom)')
    @conn.exec('CREATE INDEX _idx_bboxes ON _tile_bboxes USING gist (tile_bbox)')
  end

  ##
  # Generates tiles for given zoom and changeset.
  #
  def generate(zoom, changeset_id, options = {})
    setup_changeset_data(changeset_id)

    tile_count = -1
    begin
      @conn.transaction do |c|
        tile_count = do_generate(zoom, changeset_id, options)
      end
    rescue
      @@log.debug "Trying workaround..."
      @conn.transaction do |c|
        tile_count = do_generate(zoom, changeset_id, options.merge(:geos_bug_workaround => true))
      end
    end
    clear_changeset_data
    tile_count
  end

  ##
  # Retrieves a list of changeset ids according to given options. If --retile option is NOT specified then
  # changesets that already have tiles in the database are skipped.
  #
  def get_changeset_ids(options)
    if options[:changesets] == ['all']
      # Select changesets with geometry (bbox not null).
      sql = "SELECT id FROM changesets cs WHERE bbox IS NOT NULL"

      unless options[:retile]
        # We are NOT retiling so skip changesets that have been already tiled.
        sql += " AND NOT EXISTS (SELECT 1 FROM tiles WHERE changeset_id = cs.id)"
      end

      sql += " ORDER BY id LIMIT 1000"

      @conn.query(sql).collect {|row| row['id'].to_i}
    else
      # List of changeset ids must have been provided.
      options[:changesets]
    end
  end

  ##
  # Removes tiles for given zoom and changeset. This is useful when retiling (creating new tiles) to avoid
  # duplicate primary key error during insert.
  #
  def clear_tiles(changeset_id, zoom)
    count = @conn.query("DELETE FROM tiles WHERE changeset_id = #{changeset_id} AND zoom = #{zoom}").cmd_tuples
    @@log.debug "Removed existing tiles: #{count}"
    count
  end

  protected

  def do_generate(zoom, changeset_id, options = {})
    clear_tiles(changeset_id, zoom) if options[:retile]

    @conn.exec('TRUNCATE _tile_changes_tmp')
    @conn.exec('TRUNCATE _way_geom')
    @conn.exec('TRUNCATE _tile_bboxes')

    process_nodes(changeset_id, zoom)
    process_ways(changeset_id, zoom, options)

    # The following is a hack because of http://trac.osgeo.org/geos/ticket/600
    # First, try ST_Union (which will result in a simpler tile geometry), if that fails, go with ST_Collect.
    if !options[:geos_bug_workaround]
      count = @conn.query("INSERT INTO tiles (changeset_id, tstamp, zoom, x, y, geom)
        SELECT  #{changeset_id}, MAX(tstamp) AS tstamp, zoom, x, y, ST_Union(tile_geom)
        FROM _tile_changes_tmp tmp
        WHERE NOT ST_IsEmpty(tile_geom)
        GROUP BY zoom, x, y").cmd_tuples
    else
      count = @conn.query("INSERT INTO tiles (changeset_id, tstamp, zoom, x, y, geom)
        SELECT  #{changeset_id}, MAX(tstamp) AS tstamp, zoom, x, y, ST_Collect(tile_geom)
        FROM _tile_changes_tmp tmp
        WHERE NOT ST_IsEmpty(tile_geom)
        GROUP BY zoom, x, y").cmd_tuples
    end

    # Now generate tiles at lower zoom levels.
    #(3..16).reverse_each do |i|
    #  @@log.debug "Aggregating tiles for level #{i - 1}..."
    #  @conn.query("SELECT OWL_AggregateChangeset(#{changeset_id}, #{i}, #{i - 1})")
    #end

    count
  end

  def process_nodes(changeset_id, zoom)
    for node in get_nodes(changeset_id)
      if node['current_lat']
        tile = latlon2tile(node['current_lat'].to_f, node['current_lon'].to_f, zoom)
        @conn.query("INSERT INTO _tile_changes_tmp (el_type, tstamp, zoom, x, y, tile_geom) VALUES
          ('N', '#{node['tstamp']}', #{zoom}, #{tile[0]}, #{tile[1]},
          ST_SetSRID(ST_GeomFromText('POINT(#{node['current_lon']} #{node['current_lat']})'), 4326))")
      end

      if node['new_lat']
        tile = latlon2tile(node['new_lat'].to_f, node['new_lon'].to_f, zoom)
        @conn.query("INSERT INTO _tile_changes_tmp (el_type, tstamp, zoom, x, y, tile_geom) VALUES
          ('N', '#{node['tstamp']}', #{zoom}, #{tile[0]}, #{tile[1]},
          ST_SetSRID(ST_GeomFromText('POINT(#{node['new_lon']} #{node['new_lat']})'), 4326))")
      end
    end
  end

  def process_ways(changeset_id, zoom, options)
    for way in get_ways(changeset_id)
      next if way['both_bbox'].nil?

      @conn.exec('TRUNCATE _tile_bboxes')
      @conn.exec('TRUNCATE _way_geom')

      @conn.query("INSERT INTO _way_geom (geom, tstamp)
        SELECT
          CASE
            WHEN prev_geom IS NOT NULL AND geom IS NOT NULL THEN
              ST_Collect(geom, prev_geom)
            WHEN prev_geom IS NOT NULL THEN prev_geom
            WHEN geom IS NOT NULL THEN geom
          END, tstamp
        FROM _changeset_data WHERE id = #{way['id']} AND version = #{way['version']}")

      tiles = bbox_to_tiles(zoom, box2d_to_bbox(way["both_bbox"]))

      @@log.debug "Way #{way['id']} (#{way['version']}): processing #{tiles.size} tile(s)..."

      # Does not make sense to reduce small changesets.
      if tiles.size > 64
        size_before = tiles.size
        reduce_tiles(tiles, changeset_id, change, zoom)
        @@log.debug "Way #{way['id']} (#{way['version']}): reduced tiles: #{size_before} -> #{tiles.size}"
      end

      for tile in tiles
        x, y = tile[0], tile[1]
        lat1, lon1 = tile2latlon(x, y, zoom)
        lat2, lon2 = tile2latlon(x + 1, y + 1, zoom)

        @conn.query("INSERT INTO _tile_bboxes VALUES (#{x}, #{y}, #{zoom},
          ST_SetSRID('BOX(#{lon1} #{lat1},#{lon2} #{lat2})'::box2d, 4326))")
      end

      @@log.debug "Way #{way['id']} (#{way['version']}): created bboxes..."

      count = @conn.query("INSERT INTO _tile_changes_tmp (el_type, tstamp, zoom, x, y, tile_geom)
        SELECT 'W', tstamp, bb.zoom, bb.x, bb.y, ST_Intersection(geom, bb.tile_bbox)
        FROM _tile_bboxes bb, _way_geom
        WHERE ST_Intersects(geom, bb.tile_bbox)").cmd_tuples

      @@log.debug "Way #{way['id']} (#{way['version']}): created #{count} tile(s)"
    end
  end

  def reduce_tiles(tiles, changeset_id, change, zoom)
    for source_zoom in [4, 6, 8, 10, 11, 12, 13, 14]
      for tile in bbox_to_tiles(source_zoom, box2d_to_bbox(change["both_bbox"]))
        x, y = tile[0], tile[1]
        lat1, lon1 = tile2latlon(x, y, source_zoom)
        lat2, lon2 = tile2latlon(x + 1, y + 1, source_zoom)
        intersects = @conn.query("
          SELECT ST_Intersects(ST_SetSRID('BOX(#{lon1} #{lat1},#{lon2} #{lat2})'::box2d, 4326), geom)
          FROM _way_geom").getvalue(0, 0) == 't'
        if !intersects
          subtiles = subtiles(tile, source_zoom, zoom)
          tiles.subtract(subtiles)
        end
      end
    end
  end

  def get_nodes(changeset_id)
    @conn.query("SELECT id,
        ST_X(prev_geom) AS current_lon,
        ST_Y(prev_geom) AS current_lat,
        ST_X(geom) AS new_lon,
        ST_Y(geom) AS new_lat,
        tstamp
      FROM _changeset_data WHERE type = 'N'").to_a
  end

  def get_ways(changeset_id)
    @conn.query("SELECT id, version, Box2D(ST_Collect(prev_geom, geom)) AS both_bbox
      FROM _changeset_data WHERE type = 'W'
      ORDER BY id").to_a
  end

  def setup_changeset_data(changeset_id)
    @conn.query("CREATE TEMPORARY TABLE _changeset_data AS SELECT * FROM OWL_GetChangesetData(#{changeset_id})").to_a
  end

  def clear_changeset_data
    @conn.query("DROP TABLE IF EXISTS _changeset_data")
  end
end

end
