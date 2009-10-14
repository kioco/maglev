# Assumes p1 has been run

key = 'PERSISTENT_DB_TEST'
server = MDB::Server.server
db = server[key]
raise "Can't find db" if db.nil?

actual = db.size
raise "Expecting 4 documents but got #{actual}" unless actual == 4
