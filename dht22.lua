dofile("config.lua")

mqtt_connected = false
count = 0
temp = 0
humi = 0
rssi = 0

local ledpin = 4
gpio.mode(ledpin, gpio.OUTPUT)
gpio.write(ledpin, 1)

function blinkled()
  if not flash_led then
    return
  end
  gpio.write(ledpin, 0)
  tmr.alarm(0, 500, 0, function ()
    gpio.write(ledpin, 1)
  end)
end

function mqtt_connect()
  m:connect(mqtt_host, mqtt_port, 0, function(c)
    mqtt_connected = true
    print("mqtt online")
    if mqtt_update then
      m:subscribe("/cmd/"..node.chipid(),0,function(conn)
        print("subscribe to cmd topic")
      end)
    end
  end)
end

wifi_connect_event = function(T)
  print("Connection to AP("..T.SSID..") established!")
  print("Waiting for IP address...")
end

wifi_got_ip_event = function(T)
  print("Wifi ready! IP is: "..T.IP)
  if (send_mqtt and not mqtt_connected) then
    print("mqtt try connect to "..mqtt_host..":"..mqtt_port)
    mqtt_connect()
  end
end

wifi_disconnect_event = function(T)
  print("wifi disconnect")
end

function send_data()
  if send_aprs then
    print("aprs send "..aprs_host)
    str = aprs_prefix.."000/000g000t"..string.format("%03d", temp*9/5+32).."r000p000h"..string.format("%02d",humi).."b00000"
    str = str.."ESP8266 MAC "..wifi.sta.getmac().." RSSI: "..rssi
    print(str)
    conn = net.createUDPSocket()
    conn:send(aprs_port,aprs_host,str)
    conn:close()
    blinkled()
  end
  if send_http then
    req_url = http_url.."?mac="..wifi.sta.getmac().."&"..string.format("temp=%.1f&humi=%.1f&rssi=%d",temp,humi,rssi)
    print("http send "..req_url)
    http.get(req_url, nil, function(code, data)
      if code < 0 then
        print("HTTP request failed")
      else
        print(code, data)
        blinkled()
      end
    end)
  end
end

function func_read_dht()
  status, temp, humi, temp_dec, humi_dec = dht.readxx(dht_pin)
  if status == dht.OK then
    rssi = wifi.sta.getrssi()
    if rssi == nil then
      rssi = -100
    end
    print("DHT read count="..string.format("%d: temp=%.1f, humi=%.1f, rssi=%d",count,temp,humi,rssi))
    if mqtt_connected then
       print("mqtt publish")
       if mqtt_mode == 0 then
         m:publish(mqtt_topic .. "/temperature", string.format("%.1f", temp),0,0)
         m:publish(mqtt_topic .. "/humidity", string.format("%.1f", humi),0,0)
         m:publish(mqtt_topic .. "/rssi", string.format("%d", rssi),0,0)
       else
         m:publish(mqtt_topic, string.format("{\"temperature\": %.1f, \"humidity\": %.1f, \"rssi\": %d}", temp, humi, rssi),0,0)
       end
       blinkled()
    end
    count = count + 1
    if count == 4 then
      if wifi.sta.status() == 5 then  --STA_GOTIP
         send_data()
         if send_mqtt and not mqtt_connected then
           print("mqtt try connect to "..mqtt_host..":"..mqtt_port)
           mqtt_connect()
         end
      else
         print("wifi still connecting...")
      end
    end
    if count*3 >= send_interval then
      count = 0
    end
  elseif dht_status == dht.ERROR_CHECKSUM then
    print("DHT read Checksum error")
  elseif dht_status == dht.ERROR_TIMEOUT then
    print("DHT read Time out")
  else
    print("DHT read null")
  end
end

if send_interval < 15 then
  send_interval = 15
end

if send_mqtt then
  print("init mqtt ESP8266SensorChipID".. node.chipid().." "..mqtt_user.." "..mqtt_password)
  m = mqtt.Client("ESP8266SensorChipID" .. node.chipid() .. ")", 180, mqtt_user, mqtt_password)
  if mqtt_update then
    m:on("message",function(conn, topic, data)
      if data ~= nil then
        print(topic .. ": " .. data)
        if data == "update" then
           print("reboot into update mode")
           file.open("update.txt","w")
           file.close()
           node.restart()
        end
      end
    end)
  end
  m:on("offline", function(c)
    print("mqtt offline, try connect to "..mqtt_host..":"..mqtt_port)
    mqtt_connected = false
    mqtt_connect()
  end)
end

wifi.eventmon.register(wifi.eventmon.STA_CONNECTED, wifi_connect_event)
wifi.eventmon.register(wifi.eventmon.STA_GOT_IP, wifi_got_ip_event)
wifi.eventmon.register(wifi.eventmon.STA_DISCONNECTED, wifi_disconnect_event)

print("My MAC is: "..wifi.sta.getmac())
print("Connecting to WiFi access point...")

wifi.setmode(wifi.STATION)
wifi.sta.config({ssid=wifi_ssid, pwd=wifi_password})
wifi.sta.autoconnect(1)
wifi.sta.connect()

flashkeypressed = false
function flashkeypress()
  if flashkeypressed then
    return
  end
  flashkeypressed = true
  print("flash key pressed, next boot into config mode")
  file.open("flashkey.txt","w")
  file.close()
end

-- flash key io
gpio.mode(3, gpio.INPUT, gpio.PULLUP)
gpio.trig(3, "low", flashkeypress)

tmr.alarm(1,3000,tmr.ALARM_AUTO,func_read_dht)
