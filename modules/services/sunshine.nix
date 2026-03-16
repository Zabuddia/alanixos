# Access with http://localhost:47990
{ ... }:

{
  services.sunshine = {
    enable = true;
    autoStart = true;
    capSysAdmin = true;
  };
}
